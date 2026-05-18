#!/usr/bin/env bash
# bootstrap.sh - idempotent Mac setup: Homebrew, fish, chezmoi, dotfiles, apps.
set -euo pipefail

DOTFILES_SSH="git@github.com:jrsquared/dotfiles.git"
DOTFILES_HTTPS="https://github.com/jrsquared/dotfiles.git"
SSH_KEY="$HOME/.ssh/id_ed25519"
BREWFILE="$HOME/.config/homebrew/Brewfile"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$1"; }

# --- 0. Robustness --------------------------------------------------------
trap 'warn "bootstrap failed at line $LINENO"' ERR

# Cache sudo credentials up front and keep them fresh so later steps that need
# sudo do not re-prompt mid-run.
log "Requesting sudo access"
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done &

# Keep the Mac awake for the duration of this run.
caffeinate -dimsu -w $$ &

# --- 1. Homebrew ----------------------------------------------------------
if command -v brew >/dev/null 2>&1; then
  log "Homebrew already installed"
else
  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if [ -x /opt/homebrew/bin/brew ]; then
  BREW_PREFIX=/opt/homebrew
else
  BREW_PREFIX=/usr/local
fi
eval "$("$BREW_PREFIX/bin/brew" shellenv)"

# --- 2. fish + chezmoi ----------------------------------------------------
for pkg in fish chezmoi; do
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    log "$pkg already installed"
  else
    log "Installing $pkg"
    brew install "$pkg"
  fi
done

FISH_PATH="$BREW_PREFIX/bin/fish"

# --- 3. Make fish the default shell --------------------------------------
if grep -qxF "$FISH_PATH" /etc/shells; then
  log "fish already in /etc/shells"
else
  log "Adding $FISH_PATH to /etc/shells (sudo)"
  echo "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
fi

CURRENT_SHELL="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
if [ "$CURRENT_SHELL" = "$FISH_PATH" ]; then
  log "fish already the default shell"
else
  log "Changing default shell to fish (sudo)"
  sudo chsh -s "$FISH_PATH" "$USER"
fi

# --- 4. Ensure GitHub SSH access -----------------------------------------
# The dotfiles repo is private, so cloning it needs a working SSH key.
# `ssh -T git@github.com` always exits 1 (GitHub grants no shell), so capture
# the output and inspect it rather than relying on the exit status. stdin is
# redirected from /dev/null so ssh cannot consume the script under curl | bash.
SSH_TEST="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com </dev/null 2>&1 || true)"
if printf '%s' "$SSH_TEST" | grep -q "successfully authenticated"; then
  log "GitHub SSH access OK"
else
  warn "No working GitHub SSH key detected"
  if [ ! -f "$SSH_KEY" ]; then
    log "Generating an SSH key at $SSH_KEY"
    ssh-keygen -t ed25519 -C "$USER@$(hostname -s)" -f "$SSH_KEY" -N ""
  fi
  echo
  echo "Add this public key to GitHub, then re-run this script:"
  echo "  https://github.com/settings/keys"
  echo
  cat "${SSH_KEY}.pub"
  echo
  exit 1
fi

# --- 5. chezmoi init / apply ---------------------------------------------
CHEZMOI_SRC="$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")"
if [ -d "$CHEZMOI_SRC/.git" ]; then
  log "chezmoi already initialized, updating"
  chezmoi update --force
else
  log "Initializing chezmoi from dotfiles repo"
  if chezmoi init --apply "$DOTFILES_SSH"; then
    log "chezmoi initialized via SSH"
  else
    warn "SSH clone failed, falling back to HTTPS"
    chezmoi init --apply "$DOTFILES_HTTPS"
  fi
fi

# --- 6. Install apps from Brewfile ---------------------------------------
if [ -f "$BREWFILE" ]; then
  log "Installing apps from Brewfile"
  brew bundle --file="$BREWFILE"
else
  warn "No Brewfile at $BREWFILE, skipping brew bundle"
fi

# --- 7. macOS system defaults --------------------------------------------
log "Applying macOS defaults"
# Keyboard: fast key repeat.
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15
# Finder: show hidden files and all filename extensions.
defaults write com.apple.finder AppleShowAllFiles -bool true
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
# Do not write .DS_Store files to network or USB volumes.
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
# Screenshots: save to ~/Screenshots as PNG.
mkdir -p "$HOME/Screenshots"
defaults write com.apple.screencapture location -string "$HOME/Screenshots"
defaults write com.apple.screencapture type -string "png"
# Dock: autohide.
defaults write com.apple.dock autohide -bool true
killall Dock Finder SystemUIServer 2>/dev/null || true

# --- 8. Touch ID for sudo -------------------------------------------------
# sudo_local survives OS updates, unlike editing /etc/pam.d/sudo directly.
if sudo grep -q pam_tid.so /etc/pam.d/sudo_local 2>/dev/null; then
  log "Touch ID for sudo already enabled"
else
  log "Enabling Touch ID for sudo"
  printf 'auth       sufficient     pam_tid.so\n' \
    | sudo tee /etc/pam.d/sudo_local >/dev/null
fi

log "Done. Open a new terminal to start using fish."

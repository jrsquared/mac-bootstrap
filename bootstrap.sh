#!/usr/bin/env bash
# bootstrap.sh - idempotent Mac setup: Homebrew, fish, chezmoi, dotfiles, apps.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "bootstrap.sh only runs on macOS." >&2
  exit 1
fi

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

# --- 1. Computer name -----------------------------------------------------
# Per-machine, so set it with COMPUTER_NAME=... in the environment. Runs before
# chezmoi so hostname-based template checks render with the right name.
if [ -n "${COMPUTER_NAME:-}" ]; then
  HOST_SAFE="$(printf '%s' "$COMPUTER_NAME" | tr ' ' '-')"
  if [ "$(scutil --get LocalHostName 2>/dev/null)" = "$HOST_SAFE" ]; then
    log "Computer name already set to $COMPUTER_NAME"
  else
    log "Setting computer name to $COMPUTER_NAME"
    sudo scutil --set ComputerName "$COMPUTER_NAME"
    sudo scutil --set HostName "$HOST_SAFE"
    sudo scutil --set LocalHostName "$HOST_SAFE"
    dscacheutil -flushcache
  fi
else
  log "COMPUTER_NAME not set, leaving computer name unchanged"
fi

# --- 2. Homebrew ----------------------------------------------------------
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

# --- 3. chezmoi -----------------------------------------------------------
# chezmoi must be installed directly: it clones the dotfiles repo that contains
# the Brewfile. Everything else (fish included) comes from the Brewfile via
# `brew bundle` below.
if brew list --formula chezmoi >/dev/null 2>&1; then
  log "chezmoi already installed"
else
  log "Installing chezmoi"
  brew install chezmoi
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
  # Make the Brewfile authoritative: opt in with BOOTSTRAP_CLEANUP=1 to
  # uninstall anything not listed. Without it, just show what would be removed.
  if [ "${BOOTSTRAP_CLEANUP:-0}" = "1" ]; then
    log "Removing packages not in the Brewfile (BOOTSTRAP_CLEANUP=1)"
    brew bundle cleanup --file="$BREWFILE" --force
  else
    if ! brew bundle cleanup --file="$BREWFILE" 2>/dev/null; then
      warn "Packages above are not in the Brewfile."
      warn "Re-run with BOOTSTRAP_CLEANUP=1 to uninstall them."
    fi
  fi
else
  warn "No Brewfile at $BREWFILE, skipping brew bundle"
fi

# --- 7. Make fish the default shell --------------------------------------
FISH_PATH="$BREW_PREFIX/bin/fish"
if [ ! -x "$FISH_PATH" ]; then
  warn "fish not installed (add it to the Brewfile), skipping default-shell change"
else
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
fi

# --- 8. fish plugins (fisher) --------------------------------------------
# fish_plugins is chezmoi-managed; `fisher update` installs every plugin listed
# there and updates ones already present.
if [ -x "$FISH_PATH" ] && [ -f "$HOME/.config/fish/fish_plugins" ]; then
  log "Installing/updating fish plugins via fisher"
  "$FISH_PATH" -c '
    if not functions -q fisher
      curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
      fisher install jorgebucaran/fisher
    end
    fisher update
  '
else
  warn "fish or fish_plugins missing, skipping fish plugin update"
fi

# --- 9. Standard folders --------------------------------------------------
log "Creating standard folders"
mkdir -p "$HOME/Developer"

# --- 10. macOS system defaults -------------------------------------------
log "Applying macOS defaults"
# Keyboard: fastest practical key repeat, and repeat held keys instead of
# showing the accent popup.
defaults write NSGlobalDomain KeyRepeat -int 1
defaults write NSGlobalDomain InitialKeyRepeat -int 10
defaults write -g ApplePressAndHoldEnabled -bool false
# Text input: disable smart-quote, smart-dash, autocorrect, auto-capitalize
# substitution (curly quotes in particular break code).
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
# Finder: show hidden files and all filename extensions.
defaults write com.apple.finder AppleShowAllFiles -bool true
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
# Finder: path bar, status bar, list view, search current folder, folders on
# top, and no warning when changing a file extension.
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"
defaults write com.apple.finder _FXSortFoldersFirst -bool true
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
# Do not write .DS_Store files to network or USB volumes.
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
# Screenshots: save to ~/Screenshots as PNG, no window drop-shadow.
mkdir -p "$HOME/Screenshots"
defaults write com.apple.screencapture location -string "$HOME/Screenshots"
defaults write com.apple.screencapture type -string "png"
defaults write com.apple.screencapture disable-shadow -bool true
# Dock: autohide, smaller tiles, scale minimize, no recent apps, fast animation.
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock tilesize -int 16
defaults write com.apple.dock size-immutable -bool true
defaults write com.apple.dock mineffect -string "scale"
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock autohide-time-modifier -float 0.15
# Mission Control: do not reorder Spaces by most-recent use.
defaults write com.apple.dock mru-spaces -bool false
# Windows: faster resize animation, and expand Save/Print dialogs by default.
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true
killall Dock Finder SystemUIServer 2>/dev/null || true

# --- 11. Default app associations ----------------------------------------
# Registering iTerm via Launch Services for shell-script file types is the
# equivalent of iTerm's "Make iTerm2 Default Term" menu item.
if command -v duti >/dev/null 2>&1; then
  if [ -d "/Applications/iTerm.app" ]; then
    log "Setting iTerm as the default terminal"
    duti -s com.googlecode.iterm2 com.apple.terminal.shell-script all
    duti -s com.googlecode.iterm2 public.shell-script all
  else
    warn "iTerm missing, skipping default-terminal association"
  fi
  if [ -d "/Applications/Visual Studio Code.app" ]; then
    log "Setting VS Code as the default app for JSON files"
    duti -s com.microsoft.VSCode public.json all
  else
    warn "VS Code missing, skipping JSON association"
  fi
else
  warn "duti missing, skipping default app associations"
fi

# --- 12. Touch ID for sudo -----------------------------------------------
# sudo_local survives OS updates, unlike editing /etc/pam.d/sudo directly.
if sudo grep -q pam_tid.so /etc/pam.d/sudo_local 2>/dev/null; then
  log "Touch ID for sudo already enabled"
else
  log "Enabling Touch ID for sudo"
  printf 'auth       sufficient     pam_tid.so\n' \
    | sudo tee /etc/pam.d/sudo_local >/dev/null
fi

log "Done. Open a new terminal to start using fish."

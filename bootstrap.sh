#!/usr/bin/env bash
# bootstrap.sh - idempotent Mac setup: Homebrew, fish, chezmoi, dotfiles.
set -euo pipefail

DOTFILES_SSH="git@github.com:jrsquared/dotfiles.git"
DOTFILES_HTTPS="https://github.com/jrsquared/dotfiles.git"
SSH_KEY="$HOME/.ssh/id_ed25519"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$1"; }

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
# the output and inspect it rather than relying on the exit status.
SSH_TEST="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)"
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

log "Done. Open a new terminal to start using fish."

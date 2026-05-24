#!/usr/bin/env bash
# bootstrap.sh - idempotent Mac setup: Homebrew, fish, chezmoi, dotfiles, apps.
#
# Usage:
#   ./bootstrap.sh          install + configure (default)
#   ./bootstrap.sh doctor   verify the install is healthy
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
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$1"; }

doctor() {
  log "Running doctor: verifying system state"
  local fail=0
  check() {
    if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fail=$((fail + 1)); fi
  }
  check "Homebrew on PATH"                          'command -v brew'
  check "fish installed"                            'command -v fish'
  check "fish is the default shell"                 '[ "$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk "{print \$2}")" = "$(command -v fish)" ]'
  check "chezmoi installed"                         'command -v chezmoi'
  check "chezmoi has no pending changes"            'test -z "$(chezmoi diff)"'
  check "Brewfile exists"                           '[ -f "$BREWFILE" ]'
  check "Brewfile fully installed"                  'brew bundle check --no-upgrade --quiet --file="$BREWFILE"'
  check "gh installed"                              'command -v gh'
  check "gh authenticated"                          'gh auth status'
  check "gitleaks installed"                        'command -v gitleaks'
  check "dotfiles repo pre-push hook installed"     '[ -x "$HOME/.local/share/chezmoi/.git/hooks/pre-push" ]'
  check "atuin installed"                           'command -v atuin'
  check "direnv installed"                          'command -v direnv'
  check "1Password CLI installed"                   'command -v op'
  check "1Password SSH agent socket present"        '[ -S "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ]'
  check "Touch ID for sudo enabled"                 'sudo -n grep -q pam_tid.so /etc/pam.d/sudo_local'
  check "Screenshots folder exists"                 '[ -d "$HOME/Screenshots" ]'
  if [ "$fail" -eq 0 ]; then
    log "All checks passed"
  else
    warn "$fail check(s) failed"
  fi
  return "$fail"
}

if [ "${1:-install}" = "doctor" ]; then
  doctor
  exit $?
fi

# --- 0. Robustness --------------------------------------------------------
trap 'warn "bootstrap failed at line $LINENO"' ERR

# Cache sudo credentials up front and keep them fresh so later steps that need
# sudo do not re-prompt mid-run. The `|| break` guards keep the loop alive
# under `set -e` (a failed refresh must not silently kill the keepalive).
log "Requesting sudo access"
sudo -v
while true; do
  sudo -n true 2>/dev/null || break
  sleep 50
  kill -0 "$$" 2>/dev/null || break
done &

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
mkdir -p "$HOME/Screenshots"

# --- 10. macOS system defaults -------------------------------------------
# Applied by chezmoi: run_onchange_macos-defaults.sh.tmpl. Re-runs on every
# chezmoi apply when the file's content hash changes, so editing a default
# value there propagates without re-running bootstrap.

# --- 11. gh CLI extensions ------------------------------------------------
if command -v gh >/dev/null 2>&1; then
  for ext_repo in dlvhdr/gh-dash; do
    ext_name="${ext_repo##*/}"
    if gh extension list 2>/dev/null | awk '{print $3}' | grep -qx "$ext_repo"; then
      log "gh extension $ext_name already installed"
    else
      log "Installing gh extension $ext_name"
      gh extension install "$ext_repo" || warn "Failed to install gh extension $ext_repo"
    fi
  done
fi

# --- 12. Login items ------------------------------------------------------
# Apps that should auto-launch at login. 1Password is critical because its
# SSH agent serves keys; without it running, git push/chezmoi update fail.
LOGIN_APPS=(
  "/Applications/1Password.app"
  "/Applications/Dato.app"
  "/Applications/Lungo.app"
  "/Applications/Rectangle Pro.app"
  "/Applications/Todoist.app"
)
if EXISTING_ITEMS="$(osascript -e 'tell application "System Events" to get name of every login item' 2>/dev/null)"; then
  for app_path in "${LOGIN_APPS[@]}"; do
    app_name="$(basename "$app_path" .app)"
    if [ ! -d "$app_path" ]; then
      warn "$app_name not installed, skipping login-item add"
      continue
    fi
    if printf '%s\n' "$EXISTING_ITEMS" | tr ',' '\n' | grep -qF "$app_name"; then
      log "$app_name already in Login Items"
    else
      log "Adding $app_name to Login Items"
      osascript -e "tell application \"System Events\" to make new login item with properties {path:\"$app_path\", hidden:true}" >/dev/null
    fi
  done
fi

# --- 13. Default app associations ----------------------------------------
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

# --- 14. Touch ID for sudo -----------------------------------------------
# sudo_local survives OS updates, unlike editing /etc/pam.d/sudo directly.
if sudo grep -q pam_tid.so /etc/pam.d/sudo_local 2>/dev/null; then
  log "Touch ID for sudo already enabled"
else
  log "Enabling Touch ID for sudo"
  printf 'auth       sufficient     pam_tid.so\n' \
    | sudo tee /etc/pam.d/sudo_local >/dev/null
fi

log "Done. Open a new terminal to start using fish."

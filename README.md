# mac-bootstrap

Idempotent bootstrap script for a new Mac. It:

- installs Homebrew, fish, and chezmoi
- sets fish as the default shell
- ensures a GitHub SSH key exists
- applies the dotfiles from the private `jrsquared/dotfiles` repo
- installs apps from the chezmoi-managed Brewfile (`brew bundle`)
- applies macOS system defaults and enables Touch ID for `sudo`

This repo is public so the script can be fetched without authentication. It
contains no secrets.

## Usage

On a fresh Mac:

```sh
curl -fsSL https://raw.githubusercontent.com/jrsquared/mac-bootstrap/main/bootstrap.sh | bash
```

If the machine has no GitHub SSH key yet, the script generates one, prints the
public key, and stops. Add that key at https://github.com/settings/keys, then
re-run the same command. The script is idempotent, so re-running it (or running
it on an already-configured Mac) is safe.

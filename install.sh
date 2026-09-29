#!/usr/bin/env bash
# Installs the currently implementable wrapper components for the current user.
# No sudo/root required. Does not overwrite an existing user config.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter"

mkdir -p "$BIN_DIR" "$CONFIG_DIR"

install -m 0755 "$SCRIPT_DIR/steam-link-display-adapter.sh" "$BIN_DIR/steam-link-display-adapter"
install -m 0755 "$SCRIPT_DIR/steam-link-display-adapter-hook.sh" "$BIN_DIR/steam-link-display-adapter-hook.sh"
install -m 0755 "$SCRIPT_DIR/steam-link-display-adapter-verify-environment.sh" "$BIN_DIR/steam-link-display-adapter-verify-environment"
install -m 0755 "$SCRIPT_DIR/steam-link-display-adapter-restore.sh" "$BIN_DIR/steam-link-display-adapter-restore"

if [[ ! -e "$CONFIG_DIR/config" ]]; then
    install -m 0644 "$SCRIPT_DIR/steam-link-display-adapter.conf.example" "$CONFIG_DIR/config"
    echo "Installed new config: $CONFIG_DIR/config"
else
    echo "Existing config preserved: $CONFIG_DIR/config"
fi

printf '\nLaunch option:\n%s\n' "$BIN_DIR/steam-link-display-adapter %command%"
printf '\nInstalled files in: %s\n' "$BIN_DIR"

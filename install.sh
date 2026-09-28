#!/usr/bin/env bash
# Installs the currently implementable wrapper components for the current user.
# No sudo/root required. Does not overwrite an existing user config.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steamlink-display"

mkdir -p "$BIN_DIR" "$CONFIG_DIR"

install -m 0755 "$SCRIPT_DIR/steamlink-display-wrapper.sh" "$BIN_DIR/steam-link-virtual-display"
install -m 0755 "$SCRIPT_DIR/steamlink-display-hook.sh" "$BIN_DIR/steamlink-display-hook.sh"
install -m 0755 "$SCRIPT_DIR/steamlink-display-verify-environment.sh" "$BIN_DIR/steamlink-display-verify-environment"
install -m 0755 "$SCRIPT_DIR/steamlink-display-restore.sh" "$BIN_DIR/steamlink-display-restore"

if [[ ! -e "$CONFIG_DIR/config" ]]; then
    install -m 0644 "$SCRIPT_DIR/steamlink-display.conf.example" "$CONFIG_DIR/config"
    echo "Installed new config: $CONFIG_DIR/config"
else
    echo "Existing config preserved: $CONFIG_DIR/config"
fi

printf '\nLaunch option:\n%s\n' "$BIN_DIR/steam-link-virtual-display %command%"
printf '\nInstalled files in: %s\n' "$BIN_DIR"

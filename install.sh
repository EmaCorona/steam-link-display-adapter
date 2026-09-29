#!/usr/bin/env bash
# Installs the currently implementable wrapper components for the current user.
# No sudo/root required. Does not overwrite an existing user config.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="${HOME}/.local/bin"
LIB_DIR="${HOME}/.local/lib/steam-link-display-adapter"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter"

mkdir -p "$BIN_DIR" "$LIB_DIR" "$CONFIG_DIR"

# Public entrypoints (user commands, on PATH).
install -m 0755 "$SCRIPT_DIR/bin/steam-link-display-adapter.sh" "$BIN_DIR/steam-link-display-adapter"
install -m 0755 "$SCRIPT_DIR/bin/steam-link-display-adapter-verify-environment.sh" "$BIN_DIR/steam-link-display-adapter-verify-environment"
install -m 0755 "$SCRIPT_DIR/bin/steam-link-display-adapter-restore.sh" "$BIN_DIR/steam-link-display-adapter-restore"

# Internal library tree: loaded with `source` by the entrypoints, never executed
# directly, hence not executable (spec §12).
while IFS= read -r -d '' f; do
    rel=${f#"$SCRIPT_DIR/lib/"}
    install -m 0644 -D "$f" "$LIB_DIR/$rel"
done < <(find "$SCRIPT_DIR/lib" -type f -print0)

# Installation compatibility: earlier versions installed a single-file hook at
# these two paths. They are our own artifacts and are replaced by the module
# tree; no other user file is ever touched (spec §11).
for stale in "$BIN_DIR/steam-link-display-adapter-hook.sh" \
             "$LIB_DIR/steam-link-display-adapter-hook.sh"; do
    if [[ -e "$stale" ]]; then
        rm -f -- "$stale"
        echo "Removed obsolete file from a previous layout: $stale"
    fi
done

if [[ ! -e "$CONFIG_DIR/config" ]]; then
    install -m 0644 "$SCRIPT_DIR/config/steam-link-display-adapter.conf.example" "$CONFIG_DIR/config"
    echo "Installed new config: $CONFIG_DIR/config"
else
    echo "Existing config preserved: $CONFIG_DIR/config"
fi

printf '\nLaunch option:\n%s\n' "$BIN_DIR/steam-link-display-adapter %command%"
printf '\nInstalled files in: %s and %s\n' "$BIN_DIR" "$LIB_DIR"

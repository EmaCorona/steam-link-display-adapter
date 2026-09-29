#!/usr/bin/env bash
# shellcheck shell=bash
# Steam Link Display Adapter - launch command.
#
# Thin entrypoint: path conventions, configuration, module loading, then the
# workflow implemented in lib/core/workflow.sh. No pipeline logic lives here.
set -Eeuo pipefail

# --- path convention (single source of truth, spec §7) ----------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
# Library tree: repository checkout (<root>/lib) or installed
# (~/.local/lib/steam-link-display-adapter/). One deterministic rule, no
# fragile relative paths inside the modules.
LIB_ROOT="$PROJECT_ROOT/lib"
if [[ ! -d "$LIB_ROOT/core" ]]; then
    LIB_ROOT="$LIB_ROOT/steam-link-display-adapter"
fi

# --- configuration: defaults, then the user file (which always wins) --------
# shellcheck source=/dev/null
source "$LIB_ROOT/core/config.sh"
if [[ -f "$USER_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$USER_CONFIG"
fi
mkdir -p "$STATE_DIR" "$CONFIG_DIR"

# --- library ----------------------------------------------------------------
# shellcheck source=/dev/null
source "$LIB_ROOT/core/bootstrap.sh"
sl_load core/cli.sh
sl_load core/workflow.sh

sl_wrapper_main "$@"

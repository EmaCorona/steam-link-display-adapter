#!/usr/bin/env bash
# shellcheck shell=bash
# Steam Link Display Adapter - manual recovery command.
#
# Thin entrypoint: path conventions, configuration, module loading, then the
# recovery workflow implemented in lib/core/restore.sh.
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

# This helper honoured these knobs from the environment before the refactor;
# capture them first so sourcing the shared defaults cannot shadow them.
_sl_env_mode_timeout=${MODE_TIMEOUT_SECONDS:-}
_sl_env_poll=${POLL_INTERVAL_SECONDS:-}
_sl_env_xwl_idx=${STREAM_XWAYLAND_SERVER_INDEX:-}

# --- configuration: defaults, then the user file (which always wins) --------
# shellcheck source=/dev/null
source "$LIB_ROOT/core/config.sh"
if [[ -n "$_sl_env_mode_timeout" ]]; then MODE_TIMEOUT_SECONDS=$_sl_env_mode_timeout; fi
if [[ -n "$_sl_env_poll" ]]; then POLL_INTERVAL_SECONDS=$_sl_env_poll; fi
if [[ -n "$_sl_env_xwl_idx" ]]; then STREAM_XWAYLAND_SERVER_INDEX=$_sl_env_xwl_idx; fi
unset _sl_env_mode_timeout _sl_env_poll _sl_env_xwl_idx

CONFIG="$USER_CONFIG"
if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

# --- library ----------------------------------------------------------------
# shellcheck source=/dev/null
source "$LIB_ROOT/core/bootstrap.sh"
sl_load core/restore.sh

sl_restore_main

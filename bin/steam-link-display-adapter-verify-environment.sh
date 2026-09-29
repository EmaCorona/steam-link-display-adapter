#!/usr/bin/env bash
# shellcheck shell=bash
# Steam Link Display Adapter - read-only environment report.
#
# Thin entrypoint: path conventions, the same defaults the other commands use
# (environment overrides honoured as before), module loading, then the report
# implemented in lib/core/report.sh.
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

# Defaults for the report: environment overrides are honoured, as before.
CONNECTOR=${CONNECTOR:-DP-3}
STREAM_MODE=${STREAM_MODE:-auto}
STREAM_WIDTH=${STREAM_WIDTH:-1920}
STREAM_HEIGHT=${STREAM_HEIGHT:-1200}
STREAM_REFRESH=${STREAM_REFRESH:-60}
GAMESCOPE_WAYLAND_DISPLAY=${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}

# --- library ----------------------------------------------------------------
# shellcheck source=/dev/null
source "$LIB_ROOT/core/bootstrap.sh"
sl_load core/report.sh

sl_verify_environment_main

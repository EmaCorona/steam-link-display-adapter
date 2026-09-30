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

# Configuration: defaults, environment overrides (honoured as before) and the
# user file, so the report reflects the effective settings; the host display
# itself is reported from runtime discovery.
_sl_env_connector=${CONNECTOR:-}
_sl_env_stream_mode=${STREAM_MODE:-}
_sl_env_stream_width=${STREAM_WIDTH:-}
_sl_env_stream_height=${STREAM_HEIGHT:-}
_sl_env_stream_refresh=${STREAM_REFRESH:-}
_sl_env_gwd=${GAMESCOPE_WAYLAND_DISPLAY:-}

# shellcheck source=/dev/null
source "$LIB_ROOT/core/config.sh"
if [[ -n "$_sl_env_connector" ]]; then CONNECTOR=$_sl_env_connector; fi
if [[ -n "$_sl_env_stream_mode" ]]; then STREAM_MODE=$_sl_env_stream_mode; fi
if [[ -n "$_sl_env_stream_width" ]]; then STREAM_WIDTH=$_sl_env_stream_width; fi
if [[ -n "$_sl_env_stream_height" ]]; then STREAM_HEIGHT=$_sl_env_stream_height; fi
if [[ -n "$_sl_env_stream_refresh" ]]; then STREAM_REFRESH=$_sl_env_stream_refresh; fi
if [[ -n "$_sl_env_gwd" ]]; then GAMESCOPE_WAYLAND_DISPLAY=$_sl_env_gwd; fi
unset _sl_env_connector _sl_env_stream_mode _sl_env_stream_width _sl_env_stream_height _sl_env_stream_refresh _sl_env_gwd

if [[ -f "$USER_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$USER_CONFIG"
fi

# --- library ----------------------------------------------------------------
# shellcheck source=/dev/null
source "$LIB_ROOT/core/bootstrap.sh"
sl_load core/report.sh

sl_verify_environment_main

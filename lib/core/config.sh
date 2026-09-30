#!/usr/bin/env bash
# shellcheck shell=bash
# Configuration surface: default values of every user-overridable variable and
# the runtime paths. Sourced by the entrypoint BEFORE the user configuration
# (~/.config/steam-link-display-adapter/config), so the user file always wins.
#
# Path convention (single source of truth, spec §7):
#   SCRIPT_DIR    directory of the entrypoint
#   PROJECT_ROOT  project root (repository checkout, or ~/.local when installed)
#   LIB_ROOT      library tree (PROJECT_ROOT/lib or
#                 PROJECT_ROOT/lib/steam-link-display-adapter once installed)
#   CONFIG_DIR    user configuration directory
#   STATE_DIR     user state directory
#
# Host-related defaults changed on 2026-09-29 (host display agnostic spec):
# the physical display is discovered at runtime from Gamescope/DRM.

USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter/config"

# Host display: discovered at runtime from Gamescope/DRM (host display
# agnostic spec). 'auto' follows the connector currently selected by
# Gamescope; a manual value (e.g. 'HDMI-A-1') is an override and must match
# the active connector, otherwise the wrapper fails closed before touching
# the display.
CONNECTOR='auto'
# Streaming target preference: used as the fallback when a valid client hint
# has no compatible host mode (STREAM_NO_COMPATIBLE_FALLBACK) and as the fixed
# target when STREAM_MODE=fixed. It never describes the host: with a missing
# or stale client hint the target is the original host mode discovered at
# runtime.
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
STREAM_FPS=60
STREAM_ASPECT='16:10'
# Dynamic client resolution (spec: risoluzione Gamescope dinamica). 'auto' turns
# the client's "Maximum capture" hint into the runtime target; 'fixed' keeps the
# previous behaviour (STREAM_WIDTH/HEIGHT/REFRESH) and is the rollback switch.
STREAM_MODE='auto'
# The client capture hint is valid only if it is at most this many seconds old
# (it must belong to the session just detected, never a previous client).
STREAM_CAPTURE_HINT_MAX_AGE_SECONDS=10
# Valid hint but no aspect-compatible host mode (spec §18): auto = use the
# configured fallback only if its aspect matches the client; never = fail
# closed; always = use the configured fallback regardless.
STREAM_NO_COMPATIBLE_FALLBACK='auto'
# Aspect-ratio compatibility tolerance for the mode resolver, in percent.
STREAM_ASPECT_TOLERANCE=5
STREAM_DETECT_WINDOW_SECONDS=180
STREAM_DETECT_WAIT_SECONDS=5
# Steam host logs used as an additional "recent stream cycle" source (the
# journal loses its Steam markers across a Steam restart; these files do not).
STEAM_STREAM_LOG="${STEAM_STREAM_LOG:-$HOME/.local/share/Steam/logs/streaming_log.txt}"
STEAM_STREAM_LOG_PREV="${STEAM_STREAM_LOG_PREV:-$HOME/.local/share/Steam/logs/streaming_log.previous.txt}"
# Xwayland #1 (the game server) must be synchronized with the output before the
# game starts: the DRM/output switch alone does not move it.
STREAM_XWAYLAND_SERVER_INDEX=1
STREAM_XWAYLAND_ALLOW_SUPERRES=0
XWAYLAND_SCAN_MAX="${XWAYLAND_SCAN_MAX:-9}"
XWAYLAND_EXTRA_DISPLAYS="${XWAYLAND_EXTRA_DISPLAYS:-}"
# Upgrade note: LOCAL_WIDTH/LOCAL_HEIGHT/LOCAL_REFRESH used to describe the
# host display. They are no longer configuration; when an existing user file
# still defines them they are honoured only to complete the recovery of a
# state file written by an older build (host display agnostic spec §17).
MODE_TIMEOUT_SECONDS=5
POLL_INTERVAL_SECONDS=0.10
GAMESCOPE_DISPLAY="${DISPLAY:-}"
GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/steam-link-display-adapter"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter"
LOG_FILE="$STATE_DIR/wrapper.log"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="$STATE_DIR/lock"
MODES_FILE="$HOME/.config/gamescope/modes.cfg"
MODES_BACKUP="$STATE_DIR/modes.cfg.backup"

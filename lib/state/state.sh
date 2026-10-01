#!/usr/bin/env bash
# shellcheck shell=bash
# Transient run state: the state file (phase + run metadata + host profile)
# used by the workflow, the cleanup and the stale-state recovery. The recovery
# restores from the profile saved here, not from the current configuration
# (host display agnostic spec §15-§16).

set -Eeuo pipefail

state_write() {
    local phase=$1
    local tmp
    tmp=$(mktemp --tmpdir="$STATE_DIR" '.state.XXXXXX')
    {
        printf 'VERSION=1\n'
        printf 'PHASE=%s\n' "$phase"
        printf 'MODES_BACKUP=%s\n' "$MODES_BACKUP"
        printf 'MODES_EXISTED=%s\n' "$MODES_EXISTED"
        printf 'SCREEN_SLEEP_REQUESTED=%s\n' "$SCREEN_SLEEP_REQUESTED"
        printf 'MONITOR_POWER_MODE=%s\n' "${MONITOR_POWER_MODE:-off}"
        printf 'VIRTUAL_DISPLAY_ACTIVE=%s\n' "${VIRTUAL_DISPLAY_ACTIVE:-0}"
        printf 'VIRTUAL_DISPLAY_UNIT=%s\n' "${VIRTUAL_DISPLAY_UNIT:-}"
        printf 'VIRTUAL_DISPLAY_PORT=%s\n' "${VIRTUAL_DISPLAY_PORT:-}"
        printf 'VIRTUAL_DISPLAY_NAME=%s\n' "${VIRTUAL_DISPLAY_NAME:-}"
        printf 'VIRTUAL_DISPLAY_OUTPUT=%s\n' "${VIRTUAL_DISPLAY_OUTPUT:-}"
        printf 'XWAYLAND_SYNCED=%s\n' "$XWAYLAND_SYNCED"
        printf 'DISPLAY_BACKEND=%s\n' "${DISPLAY_BACKEND:-unknown}"
        printf 'STREAM_MODE=%s\n' "${STREAM_MODE:-auto}"
        printf 'CLIENT_WIDTH=%s\n' "${CLIENT_WIDTH:-}"
        printf 'CLIENT_HEIGHT=%s\n' "${CLIENT_HEIGHT:-}"
        printf 'CLIENT_FPS=%s\n' "${CLIENT_FPS:-}"
        printf 'TARGET_WIDTH=%s\n' "${TARGET_WIDTH:-}"
        printf 'TARGET_HEIGHT=%s\n' "${TARGET_HEIGHT:-}"
        printf 'TARGET_REFRESH=%s\n' "${TARGET_REFRESH:-}"
        printf 'TARGET_FPS=%s\n' "${TARGET_FPS:-}"
        printf 'TARGET_SOURCE=%s\n' "${TARGET_SOURCE:-}"
        printf 'TARGET_MODE_SPEC=%s\n' "${TARGET_MODE_SPEC:-}"
        printf 'ORIGINAL_CONNECTOR=%s\n' "${HOST_CONNECTOR:-}"
        printf 'ORIGINAL_PRIMARY_OUTPUT=%s\n' "${HOST_ORIGINAL_PRIMARY:-}"
        printf 'ORIGINAL_DESKTOP_LAYOUT=%s\n' "${HOST_ORIGINAL_LAYOUT:-}"
        printf 'ORIGINAL_MODE=%s\n' "${HOST_ORIGINAL_MODE:-}"
        printf 'ORIGINAL_XWAYLAND_MODE=%s\n' "${HOST_ORIGINAL_XWAYLAND_MODE:-}"
        printf 'DISPLAY_DESCRIPTION=%s\n' "${HOST_DESCRIPTION:-}"
    } >"$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
    # The run state is private: never world/group readable.
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

state_field() {
    # Read one field from the state file (empty when unavailable).
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$STATE_FILE" | head -n1
}

state_phase() {
    # PHASE is the state-machine field (spec §12).
    state_field PHASE
}

state_clear() {
    rm -f -- "$STATE_FILE"
}

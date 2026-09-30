#!/usr/bin/env bash
# shellcheck shell=bash
# Host display profile: runtime discovery of the physical host.
#
# The adapter is host-agnostic (spec: host display agnostic, 2026-09-29):
# connector, current mode, display description and the original Xwayland #1
# geometry are discovered from Gamescope/DRM at the start of the session,
# before any modification, and become the authoritative reference for the
# prepare phase and for the restore. Nothing about the physical monitor comes
# from the configuration; the run state carries the profile so that the
# stale-state recovery can restore a run it did not start.

set -Eeuo pipefail

capture_host_profile() {
    # Discover and expose the host state BEFORE any mutation (spec §10).
    # Fail-closed when the connector, the current mode or (when present) the
    # Xwayland #1 geometry cannot be determined: without them there would be
    # nothing safe to restore.
    local connector description current xwl idx
    idx=${STREAM_XWAYLAND_SERVER_INDEX:-1}

    connector=$(resolve_active_connector) || return 1
    ACTIVE_CONNECTOR=$connector
    HOST_CONNECTOR=$connector

    current=$(get_current_mode 2>/dev/null || true)
    if [[ -z "$current" ]]; then
        fail "unable to determine the current host mode (fail-closed)"
        return 1
    fi
    HOST_ORIGINAL_MODE=$current

    description=$(get_display_description 2>/dev/null || true)
    HOST_DESCRIPTION=$description

    if display_backend_supports_xwayland; then
        if xwayland_server_present "$idx"; then
            xwl=$(get_xwayland_server_mode "$idx" 2>/dev/null || true)
            if [[ -z "$xwl" ]]; then
                fail "unable to determine the original Xwayland #$idx geometry (fail-closed)"
                return 1
            fi
            HOST_ORIGINAL_XWAYLAND_MODE=$xwl
        else
            HOST_ORIGINAL_XWAYLAND_MODE=''
            log "Xwayland #$idx not present at capture; no original geometry to record"
        fi
    else
        HOST_ORIGINAL_XWAYLAND_MODE=''
        log "Display backend '$(display_backend_name)' has no Xwayland synchronization contract"
    fi

    log_event HOST_PROFILE_DETECTED "connector=${HOST_CONNECTOR} mode=${HOST_ORIGINAL_MODE} xwayland=${HOST_ORIGINAL_XWAYLAND_MODE:-unavailable}"
    log "Host display profile: connector=${HOST_CONNECTOR} mode=${HOST_ORIGINAL_MODE} description=${HOST_DESCRIPTION:-unavailable} xwayland=${HOST_ORIGINAL_XWAYLAND_MODE:-unavailable}"
    return 0
}

original_mode_for_restore() {
    # Mode the display must go back to: this session's capture, the profile
    # saved by an interrupted run (spec §16), or the legacy configuration for
    # state files written by older builds (spec §17). Empty when unknown:
    # never invent a mode.
    if [[ -n "${HOST_ORIGINAL_MODE:-}" ]]; then
        printf '%s\n' "$HOST_ORIGINAL_MODE"
        return 0
    fi
    local from_state
    from_state=$(state_field ORIGINAL_MODE 2>/dev/null || true)
    if [[ -n "$from_state" ]]; then
        printf '%s\n' "$from_state"
        return 0
    fi
    legacy_local_mode || true
    return 0
}

original_xwayland_mode_for_restore() {
    # Xwayland #1 geometry to restore, same sources as above (spec §14-§16).
    if [[ -n "${HOST_ORIGINAL_XWAYLAND_MODE:-}" ]]; then
        printf '%s\n' "$HOST_ORIGINAL_XWAYLAND_MODE"
        return 0
    fi
    local from_state
    from_state=$(state_field ORIGINAL_XWAYLAND_MODE 2>/dev/null || true)
    if [[ -n "$from_state" ]]; then
        printf '%s\n' "$from_state"
        return 0
    fi
    legacy_local_wxh || true
    return 0
}

legacy_local_mode() {
    # Compatibility fallback for state files written by builds that described
    # the host statically (spec §17). Empty on a fresh install: the LOCAL_*
    # values are never required and never installed by default.
    [[ -n "${LOCAL_WIDTH:-}" && -n "${LOCAL_HEIGHT:-}" && -n "${LOCAL_REFRESH:-}" ]] || return 0
    [[ "$LOCAL_WIDTH" =~ ^[0-9]+$ && "$LOCAL_HEIGHT" =~ ^[0-9]+$ && "$LOCAL_REFRESH" =~ ^[0-9]+$ ]] || return 0
    printf '%sx%s@%s\n' "$LOCAL_WIDTH" "$LOCAL_HEIGHT" "$LOCAL_REFRESH"
    return 0
}

legacy_local_wxh() {
    [[ -n "${LOCAL_WIDTH:-}" && -n "${LOCAL_HEIGHT:-}" ]] || return 0
    [[ "$LOCAL_WIDTH" =~ ^[0-9]+$ && "$LOCAL_HEIGHT" =~ ^[0-9]+$ ]] || return 0
    printf '%sx%s\n' "$LOCAL_WIDTH" "$LOCAL_HEIGHT"
    return 0
}

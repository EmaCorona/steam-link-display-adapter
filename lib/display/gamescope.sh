#!/usr/bin/env bash
# shellcheck shell=bash
# Gamescope / Bazzite Game Mode display backend.
#
# Owns the lifecycle steps specific to Gamescope (stream preparation, host-state
# restore, stale-state recovery). The mode primitives it builds on live in
# display/mode.sh; the workflow only calls the display/backend.sh facade.

set -Eeuo pipefail

gamescope_prepare_stream_mode() {
    local description current xwayland_current
    log_event OUTPUT_PREPARE_START
    # The description was captured with the host profile before any mutation;
    # a fresh read is only a fallback for a momentary gap at capture time.
    description="${HOST_DESCRIPTION:-}"
    [[ -n "$description" ]] || description=$(get_display_description || true)
    [[ -n "$description" ]] || {
        fail "unable to determine Gamescope display description"
        return 1
    }

    log "Gamescope display description: $description"

    # Warm-up re-poll (candidate mitigation, measured 2026-09-28): every launch
    # preceded by the stale-recovery cycle survived (3/3), while direct "clean"
    # launches crashed 5/5 in Steam's capture pipeline (libavutil/pipes asserts).
    # Reproduce the recovery's extra connector re-poll before the stream switch
    # and let it settle.
    set_dynamic_modes_allowed 1 || true
    if nudge_mode; then
        log "Warm-up re-poll sent"
        sleep 0.5
    else
        log "WARNING: warm-up re-poll failed (continuing)"
    fi

    backup_modes_file
    state_write 'PREPARING'
    write_saved_mode_for_description "$description" "$TARGET_WIDTH" "$TARGET_HEIGHT" "$TARGET_REFRESH"

    set_dynamic_modes_allowed 1
    log "Dynamic external display modes enabled"

    if ! nudge_mode; then
        fail "Gamescope mode re-poll failed"
        return 1
    fi
    log "Gamescope display-mode nudge sent"

    if ! wait_for_target_mode; then
        current=$(get_current_mode 2>/dev/null || printf 'unknown')
        fail "target mode not reached within ${MODE_TIMEOUT_SECONDS}s (current=$current)"
        return 1
    fi

    current=$(get_current_mode 2>/dev/null || printf '%sx%s@%s' "$TARGET_WIDTH" "$TARGET_HEIGHT" "$TARGET_REFRESH")
    log "Verified target mode: ${current} (source=${TARGET_SOURCE})"
    log_event OUTPUT_TARGET_REACHED "$current"

    # Xwayland #1 (the game server) does not follow the output switch: sync it
    # explicitly and only proceed once its root geometry is the target.
    log_event XWAYLAND1_SYNC_REQUESTED "${STREAM_XWAYLAND_SERVER_INDEX}/${TARGET_WIDTH}/${TARGET_HEIGHT}/${STREAM_XWAYLAND_ALLOW_SUPERRES}"
    if ! set_stream_xwayland_mode; then
        fail "could not request Xwayland #${STREAM_XWAYLAND_SERVER_INDEX} mode ${TARGET_WIDTH}x${TARGET_HEIGHT}"
        return 1
    fi
    if ! wait_for_stream_xwayland_mode; then
        xwayland_current=$(get_xwayland_server_mode "$STREAM_XWAYLAND_SERVER_INDEX" 2>/dev/null || printf 'unknown')
        fail "Xwayland #${STREAM_XWAYLAND_SERVER_INDEX} not ${TARGET_WIDTH}x${TARGET_HEIGHT} within ${MODE_TIMEOUT_SECONDS}s (current=$xwayland_current)"
        return 1
    fi
    XWAYLAND_SYNCED=1
    XWAYLAND_SYNC_CONFIRMED_NS=$(date +%s%N)
    log_event XWAYLAND1_SYNC_CONFIRMED "$(get_xwayland_server_mode "$STREAM_XWAYLAND_SERVER_INDEX" 2>/dev/null || true)"
    # PREPARED: output + Xwayland #1 are both at the target, before GAME_LAUNCH
    # (spec §12 sequence: OUT/XWAYLAND_READY -> PREPARED -> GAME_LAUNCH).
    state_write 'PREPARED'

    state_write 'STREAMING'
    SETUP_DONE=1
}

gamescope_restore_host_state() {
    local original_mode original_xwl

    if (( BACKUP_TAKEN || STALE_STATE_LOADED )) && [[ -f "$MODES_BACKUP" ]]; then
        if restore_modes_file; then
            log "modes.cfg restored from backup"
        else
            log "CRITICAL: failed to restore modes.cfg"
        fi
    else
        log "No modes.cfg snapshot owned by this run; leaving modes.cfg untouched"
    fi

    original_mode=$(original_mode_for_restore)
    original_xwl=$(original_xwayland_mode_for_restore)

    if (( BACKUP_TAKEN || STALE_STATE_LOADED )) && command -v xprop >/dev/null 2>&1 && [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]]; then
        if gamescope_nudge_mode; then
            log "Gamescope local-mode nudge sent"
            if [[ -n "$original_mode" ]]; then
                if wait_for_original_mode "$original_mode"; then
                    log "Verified original mode: $original_mode"
                else
                    log "CRITICAL: original mode verification timed out"
                fi
            fi
        else
            log "CRITICAL: failed to nudge Gamescope during restore"
        fi
    fi

    if (( BACKUP_TAKEN || STALE_STATE_LOADED )) && command -v gamescopectl >/dev/null 2>&1; then
        if gamescope_set_dynamic_modes_allowed 0; then
            log "Dynamic external display modes disabled"
        else
            log "WARNING: failed to disable dynamic external display modes"
        fi
    fi

    if (( BACKUP_TAKEN || STALE_STATE_LOADED )) && xwayland_server_present "${STREAM_XWAYLAND_SERVER_INDEX:-1}"; then
        if [[ -n "$original_xwl" ]]; then
            log_event XWAYLAND1_RESTORE "${STREAM_XWAYLAND_SERVER_INDEX:-1}/$original_xwl"
            if restore_stream_xwayland_mode "$original_xwl"; then
                log "Xwayland #${STREAM_XWAYLAND_SERVER_INDEX:-1} restored to $original_xwl"
            else
                log "WARNING: could not restore Xwayland #${STREAM_XWAYLAND_SERVER_INDEX:-1} geometry"
            fi
        fi
        XWAYLAND_SYNCED=0
    fi

    rm -f -- "$MODES_BACKUP" 2>/dev/null || true
}

gamescope_recover_stale_state() {
    local verify_mode stale_xwl
    MODES_EXISTED=$(state_field MODES_EXISTED 2>/dev/null || printf '0')
    MODES_BACKUP=$(state_field MODES_BACKUP 2>/dev/null || true)
    verify_mode=$(original_mode_for_restore)
    stale_xwl=$(original_xwayland_mode_for_restore)

    log "Saved run profile: connector=$(state_field ORIGINAL_CONNECTOR 2>/dev/null || true) mode=${verify_mode:-unavailable} xwayland=${stale_xwl:-unavailable}"

    if [[ -f "$MODES_BACKUP" ]]; then
        restore_modes_file || {
            log "ERROR: stale-state recovery could not restore modes.cfg"
            return 1
        }
    else
        log "ERROR: stale state exists but backup is missing"
        return 1
    fi
    if [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]]; then
        if ! gamescope_nudge_mode; then
            log "ERROR: stale-state recovery could not nudge Gamescope"
            return 1
        fi
        if [[ -n "$verify_mode" ]]; then
            if ! wait_for_original_mode "$verify_mode"; then
                log "ERROR: stale-state recovery could not verify the original mode"
                return 1
            fi
            log "Verified original mode: $verify_mode"
        else
            log "WARNING: no original mode recorded (state without a saved profile); skipping mode verification"
        fi
    fi
    gamescope_set_dynamic_modes_allowed 0 || {
        log "ERROR: stale-state recovery could not disable dynamic modes"
        return 1
    }
    if xwayland_server_present "${STREAM_XWAYLAND_SERVER_INDEX:-1}"; then
        if [[ -n "$stale_xwl" ]]; then
            if restore_stream_xwayland_mode "$stale_xwl"; then
                log "Stale-state recovery restored Xwayland #${STREAM_XWAYLAND_SERVER_INDEX:-1} to $stale_xwl"
            else
                log "WARNING: stale-state recovery could not restore Xwayland #${STREAM_XWAYLAND_SERVER_INDEX:-1}"
            fi
        else
            log "WARNING: stale-state recovery: no original Xwayland geometry recorded; skipping"
        fi
    fi
    XWAYLAND_SYNCED=0
    HOST_ORIGINAL_MODE=${verify_mode:-${HOST_ORIGINAL_MODE:-}}
    HOST_ORIGINAL_XWAYLAND_MODE=${stale_xwl:-${HOST_ORIGINAL_XWAYLAND_MODE:-}}
    rm -f -- "$MODES_BACKUP" 2>/dev/null || true
}

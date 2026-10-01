#!/usr/bin/env bash
# shellcheck shell=bash
# Manual recovery workflow (orchestration, spec: recovery and cleanup).
#
# Conservative: it only puts the environment back to the original host state
# and never enters streaming mode. The original state comes from the run state
# file (the profile saved by the interrupted run) or, for state files written
# by older builds, from the legacy configuration if it is still present; it is
# never guessed from the current configuration (host display agnostic spec
# §16-§17). Every concrete operation is delegated to the domain modules.

sl_restore_main() {
    mkdir -p "$STATE_DIR"

    printf '[%s] restore: starting\n' "$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ -f "$STATE_FILE" ]]; then
        state_backup=$(sed -n 's/^MODES_BACKUP=//p' "$STATE_FILE" | head -n1 || true)
        [[ -n "$state_backup" ]] && MODES_BACKUP=$state_backup
        MODES_EXISTED=$(sed -n 's/^MODES_EXISTED=//p' "$STATE_FILE" | head -n1 || printf '0')
        state_xwayland_synced=$(sed -n 's/^XWAYLAND_SYNCED=//p' "$STATE_FILE" | head -n1 || printf '0')
        saved_backend=$(sed -n 's/^DISPLAY_BACKEND=//p' "$STATE_FILE" | head -n1 || true)
        saved_sleep=$(sed -n 's/^SCREEN_SLEEP_REQUESTED=//p' "$STATE_FILE" | head -n1 || printf '0')
        [[ -n "$saved_backend" ]] && DISPLAY_BACKEND=$saved_backend
        SCREEN_SLEEP_REQUESTED=$saved_sleep
    fi

    # Original display state: the profile saved by the interrupted run when
    # present, the legacy configuration for state files written by older
    # builds (spec §16-§17). Never guessed from the current configuration.
    local original_mode original_xwl
    original_mode=$(original_mode_for_restore)
    original_xwl=$(original_xwayland_mode_for_restore)

    if [[ "${SCREEN_SLEEP_REQUESTED:-0}" == 1 ]]; then
        display_backend_restore_monitor_power || true
        printf '[%s] restore: monitor wake requested\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    fi

    if [[ -n "$MODES_BACKUP" && -f "$MODES_BACKUP" ]]; then
        if (( MODES_EXISTED )); then
            mkdir -p "$(dirname -- "$MODES_FILE")"
            tmp=$(mktemp --tmpdir="$(dirname -- "$MODES_FILE")" '.modes.cfg.restore.XXXXXX')
            cp --reflink=auto -- "$MODES_BACKUP" "$tmp"
            mv -f -- "$tmp" "$MODES_FILE"
        else
            rm -f -- "$MODES_FILE"
        fi
        printf '[%s] restore: stale modes.cfg snapshot restored\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    fi

    if [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]]; then
        if nudge_mode; then
            printf '[%s] restore: Gamescope nudge sent\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            if [[ -n "$original_mode" ]]; then
                if wait_for_original_mode "$original_mode"; then
                    printf '[%s] restore: original mode verified: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$original_mode"
                else
                    printf '[%s] restore: WARNING could not verify original mode %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$original_mode"
                fi
            else
                printf '[%s] restore: WARNING no original mode recorded; skipping verification\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            fi
        fi
    fi

    set_dynamic_modes_allowed 0 || true

    if xwayland_server_present "$STREAM_XWAYLAND_SERVER_INDEX"; then
        if [[ -n "$original_xwl" ]]; then
            if restore_stream_xwayland_mode "$original_xwl"; then
                printf '[%s] restore: Xwayland #%s geometry restored to %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$STREAM_XWAYLAND_SERVER_INDEX" "$original_xwl"
            else
                printf '[%s] restore: WARNING could not restore Xwayland #%s geometry\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$STREAM_XWAYLAND_SERVER_INDEX"
            fi
        else
            printf '[%s] restore: WARNING no original Xwayland geometry recorded; skipping\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        fi
    fi

    rm -f -- "$MODES_BACKUP" 2>/dev/null || true
    rm -f -- "$STATE_FILE"

    printf '[%s] restore: finished\n' "$(date '+%Y-%m-%d %H:%M:%S')"
}

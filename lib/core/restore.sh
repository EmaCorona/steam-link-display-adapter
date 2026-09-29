#!/usr/bin/env bash
# shellcheck shell=bash
# Manual recovery workflow (orchestration, spec: recovery and cleanup).
#
# Conservative: it only puts the environment back to the local state and never
# enters streaming mode. Every concrete operation is delegated to the domain
# modules; the observable output is unchanged.

sl_restore_main() {
    mkdir -p "$STATE_DIR"

    printf '[%s] restore: starting\n' "$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ -f "$STATE_FILE" ]]; then
        state_backup=$(sed -n 's/^MODES_BACKUP=//p' "$STATE_FILE" | head -n1 || true)
        [[ -n "$state_backup" ]] && MODES_BACKUP=$state_backup
        MODES_EXISTED=$(sed -n 's/^MODES_EXISTED=//p' "$STATE_FILE" | head -n1 || printf '0')
        state_xwayland_synced=$(sed -n 's/^XWAYLAND_SYNCED=//p' "$STATE_FILE" | head -n1 || printf '0')
    fi

    screen_wake || true
    printf '[%s] restore: screen wake requested\n' "$(date '+%Y-%m-%d %H:%M:%S')"

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
            wait_for_local_mode || true
        fi
    fi

    set_dynamic_modes_allowed 0 || true

    if xwayland_server_present "$STREAM_XWAYLAND_SERVER_INDEX"; then
        if restore_stream_xwayland_mode; then
            printf '[%s] restore: Xwayland #%s geometry restored to %sx%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$STREAM_XWAYLAND_SERVER_INDEX" "$LOCAL_WIDTH" "$LOCAL_HEIGHT"
        else
            printf '[%s] restore: WARNING could not restore Xwayland #%s geometry\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$STREAM_XWAYLAND_SERVER_INDEX"
        fi
    fi

    rm -f -- "$MODES_BACKUP" 2>/dev/null || true
    rm -f -- "$STATE_FILE"

    printf '[%s] restore: finished\n' "$(date '+%Y-%m-%d %H:%M:%S')"
}

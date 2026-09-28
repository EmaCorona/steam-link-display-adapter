#!/usr/bin/env bash
# Conservative manual recovery helper.
# Never enters streaming mode. Intended for stale-state recovery.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/steamlink-display/config"
HOOK="$SCRIPT_DIR/steamlink-display-hook.sh"

LOCAL_WIDTH=3440
LOCAL_HEIGHT=1440
LOCAL_REFRESH=165
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/steamlink-display"
STATE_FILE="$STATE_DIR/state"
GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}"
GAMESCOPE_DISPLAY="${DISPLAY:-}"
MODES_FILE="$HOME/.config/gamescope/modes.cfg"
MODES_BACKUP="$STATE_DIR/modes.cfg.backup"
MODES_EXISTED=0
MODE_TIMEOUT_SECONDS="${MODE_TIMEOUT_SECONDS:-5}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-0.10}"
STREAM_XWAYLAND_SERVER_INDEX="${STREAM_XWAYLAND_SERVER_INDEX:-1}"

if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi
# shellcheck disable=SC1091
source "$HOOK"

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

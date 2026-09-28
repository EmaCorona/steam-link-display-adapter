#!/usr/bin/env bash
# shellcheck shell=bash
# Steam launch wrapper for Bazzite Game Mode / Gamescope.
# Target: 1920x1200 @ 60 Hz, 16:10, 60 FPS streaming.
# HANDOFF: environment-specific completion point is intentionally isolated in
# steamlink-display-hook.sh. Handoff adaptations were applied there on 2026-09-28
# (gamescopectl backend_set_dirty re-poll, journal mode readback); the remaining
# in-session validation in Game Mode is tracked in the package README.
# 2026-09-28 (spec utente): the display pipeline runs only when
# steam_link_streaming_active() (hook) detects an active Steam Link session;
# otherwise the game command is launched directly (no display changes).
# 2026-09-29 (spec "Sincronizzazione Xwayland #1"): the output mode and the
# Xwayland #1 (game) server mode are two distinct states. After the output is
# verified at 1920x1200@60 the wrapper explicitly syncs Xwayland #1 to
# 1920x1200 through GAMESCOPE_XWAYLAND_MODE_CONTROL and verifies its root
# geometry; the game is launched only after XWAYLAND1_SYNC_CONFIRMED.
#
# IMPORTANT:
# - This wrapper is intentionally fail-closed.
# - It NEVER turns the physical display off unless the target Gamescope mode
#   was verified first.
# - The actual Gamescope integration lives in steamlink-display-hook.sh.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/steamlink-display-hook.sh"
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/steamlink-display/config"

CONNECTOR='DP-3'
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
STREAM_FPS=60
STREAM_ASPECT='16:10'
STREAM_ALT_REFRESHES='164'
STREAM_DETECT_WINDOW_SECONDS=180
STREAM_DETECT_WAIT_SECONDS=5
# Xwayland #1 (the game server) must be synchronized with the output before the
# game starts: the DRM/output switch alone does not move it.
STREAM_XWAYLAND_SERVER_INDEX=1
STREAM_XWAYLAND_ALLOW_SUPERRES=0
XWAYLAND_SCAN_MAX="${XWAYLAND_SCAN_MAX:-9}"
XWAYLAND_EXTRA_DISPLAYS="${XWAYLAND_EXTRA_DISPLAYS:-}"
LOCAL_WIDTH=3440
LOCAL_HEIGHT=1440
LOCAL_REFRESH=165
MODE_TIMEOUT_SECONDS=5
POLL_INTERVAL_SECONDS=0.10
GAMESCOPE_DISPLAY="${DISPLAY:-}"
GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/steamlink-display"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steamlink-display"
LOG_FILE="$STATE_DIR/wrapper.log"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="$STATE_DIR/lock"
MODES_FILE="$HOME/.config/gamescope/modes.cfg"

if [[ -f "$USER_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$USER_CONFIG"
fi

mkdir -p "$STATE_DIR" "$CONFIG_DIR"

# shellcheck disable=SC1091
source "$HOOK"

if [[ $# -eq 0 ]]; then
    printf 'Usage: %s <game-command> [args...]\n' "$0" >&2
    exit 64
fi

log_file() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

log() {
    log_file "$*"
}

# Monotonic, wrapper-relative event log (spec: STREAM_DETECTED, OUTPUT_PREPARE_START,
# OUTPUT_TARGET_REACHED, XWAYLAND1_SYNC_REQUESTED, XWAYLAND1_SYNC_CONFIRMED,
# GAME_LAUNCH). Format: "T<ms>ms <EVENT> [detail]".
WRAPPER_START_NS=$(date +%s%N)
XWAYLAND_SYNC_CONFIRMED_NS=0

now_ms() {
    printf '%s\n' $(( ($(date +%s%N) - WRAPPER_START_NS) / 1000000 ))
}

log_event() {
    log "T$(now_ms)ms $1${2:+ $2}"
}

fail() {
    log "ERROR: $*"
    printf 'steamlink-display-wrapper: ERROR: %s\n' "$*" >&2
    return 1
}

lock_acquire() {
    exec 9>"$LOCK_FILE"
    flock -n 9
}

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
        printf 'XWAYLAND_SYNCED=%s\n' "$XWAYLAND_SYNCED"
    } >"$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

state_phase() {
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n 's/^PHASE=//p' "$STATE_FILE" | head -n1
}

state_clear() {
    rm -f -- "$STATE_FILE"
}

MODES_BACKUP="$STATE_DIR/modes.cfg.backup"
MODES_EXISTED=0
SETUP_DONE=0
SCREEN_SLEEP_REQUESTED=0
CLEANUP_DONE=0
GAME_EXIT_CODE=0
BACKUP_TAKEN=0
STALE_STATE_LOADED=0
XWAYLAND_SYNCED=0

backup_modes_file() {
    rm -f -- "$MODES_BACKUP"
    if [[ -f "$MODES_FILE" ]]; then
        cp --reflink=auto -- "$MODES_FILE" "$MODES_BACKUP"
        MODES_EXISTED=1
    else
        : >"$MODES_BACKUP"
        MODES_EXISTED=0
    fi
    BACKUP_TAKEN=1
    log "Backed up modes.cfg to $MODES_BACKUP (existed=$MODES_EXISTED)"
}

restore_modes_file() {
    [[ -n "$MODES_BACKUP" ]] || return 0
    if (( MODES_EXISTED )); then
        mkdir -p "$(dirname -- "$MODES_FILE")"
        local tmp
        tmp=$(mktemp --tmpdir="$(dirname -- "$MODES_FILE")" '.modes.cfg.restore.XXXXXX')
        cp --reflink=auto -- "$MODES_BACKUP" "$tmp"
        mv -f -- "$tmp" "$MODES_FILE"
    else
        rm -f -- "$MODES_FILE"
    fi
    log "Restored modes.cfg"
}

write_saved_mode_for_description() {
    local description=$1
    local width=$2
    local height=$3
    local refresh=$4
    local tmp dir

    dir=$(dirname -- "$MODES_FILE")
    mkdir -p "$dir"
    tmp=$(mktemp --tmpdir="$dir" '.modes.cfg.stream.XXXXXX')

    if [[ -f "$MODES_FILE" ]]; then
        awk -v d="$description" -v w="$width" -v h="$height" -v r="$refresh" '
            BEGIN { replaced=0 }
            {
                line=$0
                split(line, a, ":")
                if (index(line, ":") > 0 && a[1] == d) {
                    if (!replaced) {
                        printf "%s:%dx%d@%d\n", d, w, h, r
                        replaced=1
                    }
                    next
                }
                print line
            }
            END {
                if (!replaced)
                    printf "%s:%dx%d@%d\n", d, w, h, r
            }
        ' "$MODES_FILE" >"$tmp"
    else
        printf '%s:%dx%d@%d\n' "$description" "$width" "$height" "$refresh" >"$tmp"
    fi

    mv -f -- "$tmp" "$MODES_FILE"
    log "Configured saved mode: ${description}:${width}x${height}@${refresh}"
}

cleanup() {
    local rc=$?

    if (( CLEANUP_DONE )); then
        return "$rc"
    fi
    CLEANUP_DONE=1

    log "Cleanup started (state=$(state_phase || true))"

    # Safety priority: wake the monitor first.
    if (( SCREEN_SLEEP_REQUESTED )); then
        if screen_wake; then
            log "External screen wake requested"
        else
            log "CRITICAL: failed to wake external screen"
        fi
        SCREEN_SLEEP_REQUESTED=0
    fi

    if (( BACKUP_TAKEN || STALE_STATE_LOADED )) && [[ -f "$MODES_BACKUP" ]]; then
        if restore_modes_file; then
            log "modes.cfg restored from backup"
        else
            log "CRITICAL: failed to restore modes.cfg"
        fi
    else
        log "No modes.cfg snapshot owned by this run; leaving modes.cfg untouched"
    fi

    if (( BACKUP_TAKEN || STALE_STATE_LOADED )) && command -v xprop >/dev/null 2>&1 && [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]]; then
        if nudge_mode; then
            log "Gamescope local-mode nudge sent"
            if wait_for_local_mode; then
                log "Verified local mode: ${LOCAL_WIDTH}x${LOCAL_HEIGHT}@${LOCAL_REFRESH}"
            else
                log "CRITICAL: local mode verification timed out"
            fi
        else
            log "CRITICAL: failed to nudge Gamescope during restore"
        fi
    fi

    if (( BACKUP_TAKEN || STALE_STATE_LOADED )) && command -v gamescopectl >/dev/null 2>&1; then
        if set_dynamic_modes_allowed 0; then
            log "Dynamic external display modes disabled"
        else
            log "WARNING: failed to disable dynamic external display modes"
        fi
    fi

    # Xwayland #1 does not follow the output switch (measured live in Gaming
    # Mode 2026-09-29: the output change updated only server #0). Whenever this
    # run restored the output -- its own snapshot or a recovered stale state --
    # bring #1 back to the local geometry too, independently of the
    # XWAYLAND_SYNCED field: a state written by an older build does not carry it.
    if (( BACKUP_TAKEN || STALE_STATE_LOADED )); then
        if xwayland_server_present "$STREAM_XWAYLAND_SERVER_INDEX"; then
            log_event XWAYLAND1_RESTORE "${STREAM_XWAYLAND_SERVER_INDEX}/${LOCAL_WIDTH}/${LOCAL_HEIGHT}"
            if restore_stream_xwayland_mode; then
                log "Xwayland #${STREAM_XWAYLAND_SERVER_INDEX} restored to ${LOCAL_WIDTH}x${LOCAL_HEIGHT}"
            else
                log "WARNING: could not restore Xwayland #${STREAM_XWAYLAND_SERVER_INDEX} geometry"
            fi
        else
            log "Xwayland #${STREAM_XWAYLAND_SERVER_INDEX} not present; nothing to restore"
        fi
        XWAYLAND_SYNCED=0
    fi

    rm -f -- "$MODES_BACKUP" 2>/dev/null || true
    state_clear
    log "Cleanup finished"

    return "$rc"
}

recover_stale_state() {
    local previous stale_backup stale_existed stale_synced
    previous=$(state_phase || true)
    [[ -n "$previous" ]] || return 0

    log "Stale state detected: $previous"
    log "Running conservative recovery before starting new game"
    STALE_STATE_LOADED=1

    stale_backup=$(sed -n 's/^MODES_BACKUP=//p' "$STATE_FILE" | head -n1 || true)
    stale_existed=$(sed -n 's/^MODES_EXISTED=//p' "$STATE_FILE" | head -n1 || true)
    stale_synced=$(sed -n 's/^XWAYLAND_SYNCED=//p' "$STATE_FILE" | head -n1 || true)
    [[ -n "$stale_backup" ]] && MODES_BACKUP=$stale_backup
    MODES_EXISTED=${stale_existed:-0}
    XWAYLAND_SYNCED=${stale_synced:-0}

    if ! screen_wake; then
        log "ERROR: stale-state recovery could not wake external screen"
        return 1
    fi

    if [[ -f "$MODES_BACKUP" ]]; then
        if ! restore_modes_file; then
            log "ERROR: stale-state recovery could not restore modes.cfg"
            return 1
        fi
    else
        log "ERROR: stale state exists but backup is missing"
        return 1
    fi

    if [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]]; then
        if ! nudge_mode; then
            log "ERROR: stale-state recovery could not nudge Gamescope"
            return 1
        fi
        if ! wait_for_local_mode; then
            log "ERROR: stale-state recovery could not verify local mode"
            return 1
        fi
    fi

    if ! set_dynamic_modes_allowed 0; then
        log "ERROR: stale-state recovery could not disable dynamic modes"
        return 1
    fi

    if xwayland_server_present "$STREAM_XWAYLAND_SERVER_INDEX"; then
        if restore_stream_xwayland_mode; then
            log "Stale-state recovery restored Xwayland #${STREAM_XWAYLAND_SERVER_INDEX} to ${LOCAL_WIDTH}x${LOCAL_HEIGHT}"
        else
            log "WARNING: stale-state recovery could not restore Xwayland #${STREAM_XWAYLAND_SERVER_INDEX}"
        fi
    fi
    XWAYLAND_SYNCED=0

    rm -f -- "$MODES_BACKUP" 2>/dev/null || true
    state_clear
    log "Stale-state recovery complete"
}

validate_config() {
    [[ "$STREAM_WIDTH" -eq 1920 && "$STREAM_HEIGHT" -eq 1200 ]] || fail "stream resolution must be 1920x1200"
    [[ "$STREAM_REFRESH" -eq 60 ]] || fail "stream refresh must be 60 Hz"
    [[ "$STREAM_FPS" -eq 60 ]] || fail "stream FPS target must be 60"
    [[ "$STREAM_ASPECT" == '16:10' ]] || fail "stream aspect must be 16:10"
    [[ -n "$CONNECTOR" ]] || fail "CONNECTOR is empty"
    [[ "$MODE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "MODE_TIMEOUT_SECONDS invalid"
    [[ "$STREAM_XWAYLAND_SERVER_INDEX" =~ ^[0-9]+$ ]] || fail "STREAM_XWAYLAND_SERVER_INDEX invalid"
    [[ "$STREAM_XWAYLAND_ALLOW_SUPERRES" =~ ^[01]$ ]] || fail "STREAM_XWAYLAND_ALLOW_SUPERRES must be 0 or 1"
}

precheck() {
    require_cmd gamescopectl
    require_cmd xprop
    require_cmd xdpyinfo
    require_cmd flock
    require_cmd journalctl

    [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]] || fail "DISPLAY/GAMESCOPE_DISPLAY is not set"

    local actual_connector
    actual_connector=$(get_connector_name || true)
    if [[ -z "$actual_connector" ]]; then
        fail "Gamescope connector not reachable via gamescopectl (is the Gaming Mode session running?)"
        return 1
    fi
    [[ "$actual_connector" == "$CONNECTOR" ]] || {
        fail "Gamescope connector is '$actual_connector', expected '$CONNECTOR'"
        return 1
    }

    log "Gamescope connector verified: $actual_connector"

    mode_list_contains "${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_REFRESH}" || {
        fail "Gamescope does not currently advertise ${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_REFRESH}"
        return 1
    }

    log "Target mode is advertised by Gamescope"
}

prepare_stream_mode() {
    local description current xwayland_current
    log_event OUTPUT_PREPARE_START
    description=$(get_display_description || true)
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
    write_saved_mode_for_description "$description" "$STREAM_WIDTH" "$STREAM_HEIGHT" "$STREAM_REFRESH"

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

    current=$(get_current_mode 2>/dev/null || printf '%sx%s@%s' "$STREAM_WIDTH" "$STREAM_HEIGHT" "$STREAM_REFRESH")
    log "Verified target mode: ${current} (${STREAM_ASPECT})"
    log_event OUTPUT_TARGET_REACHED "$current"

    # Xwayland #1 (the game server) does not follow the output switch: sync it
    # explicitly and only proceed once its root geometry is the target.
    log_event XWAYLAND1_SYNC_REQUESTED "${STREAM_XWAYLAND_SERVER_INDEX}/${STREAM_WIDTH}/${STREAM_HEIGHT}/${STREAM_XWAYLAND_ALLOW_SUPERRES}"
    if ! set_stream_xwayland_mode; then
        fail "could not request Xwayland #${STREAM_XWAYLAND_SERVER_INDEX} mode ${STREAM_WIDTH}x${STREAM_HEIGHT}"
        return 1
    fi
    if ! wait_for_stream_xwayland_mode; then
        xwayland_current=$(get_xwayland_server_mode "$STREAM_XWAYLAND_SERVER_INDEX" 2>/dev/null || printf 'unknown')
        fail "Xwayland #${STREAM_XWAYLAND_SERVER_INDEX} not ${STREAM_WIDTH}x${STREAM_HEIGHT} within ${MODE_TIMEOUT_SECONDS}s (current=$xwayland_current)"
        return 1
    fi
    XWAYLAND_SYNCED=1
    XWAYLAND_SYNC_CONFIRMED_NS=$(date +%s%N)
    log_event XWAYLAND1_SYNC_CONFIRMED "$(get_xwayland_server_mode "$STREAM_XWAYLAND_SERVER_INDEX" 2>/dev/null || true)"

    SCREEN_SLEEP_REQUESTED=1
    if ! screen_sleep; then
        fail "failed to put the external screen to sleep"
        return 1
    fi
    log "External screen sleep requested"

    state_write 'STREAMING'
    SETUP_DONE=1
}

run_game() {
    local now_ns
    now_ns=$(date +%s%N)
    # Invariant (spec): the game must not start before Xwayland #1 was confirmed.
    if (( XWAYLAND_SYNC_CONFIRMED_NS == 0 || now_ns <= XWAYLAND_SYNC_CONFIRMED_NS )); then
        fail "refusing to launch: XWAYLAND1_SYNC_CONFIRMED must precede GAME_LAUNCH"
        return 1
    fi

    log_event GAME_LAUNCH "$(printf '%q ' "$@")"
    log "Launching game: $(printf '%q ' "$@")"

    "$@" &
    GAME_PID=$!
    log "Game PID: $GAME_PID"

    wait "$GAME_PID" || GAME_EXIT_CODE=$?
    log "Game exited with code $GAME_EXIT_CODE"
    return 0
}

trap 'rc=$?; cleanup; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

LOCK_HELD=0

# Stale-state recovery has priority over the bypass decision: a previous
# interrupted run may have left the display in a modified state.
if [[ -f "$STATE_FILE" ]]; then
    if lock_acquire; then
        LOCK_HELD=1
        recover_stale_state || log "WARNING: stale-state recovery failed; continuing"
    else
        log "WARNING: another instance is active; skipping stale-state recovery"
    fi
fi

# Steam Link decision: run the display pipeline only when a streaming session
# is actually active; otherwise bypass with a direct launch.
if steam_link_streaming_active; then
    if (( ! LOCK_HELD )); then
        if ! lock_acquire; then
            printf 'steamlink-display-wrapper: another instance is already active\n' >&2
            exit 73
        fi
        LOCK_HELD=1
    fi
    log "Steam Link streaming session detected: running display pipeline"
    log_event STREAM_DETECTED
    validate_config
    precheck
    prepare_stream_mode
    if ! run_game "$@"; then
        exit 1
    fi
    exit "$GAME_EXIT_CODE"
fi

log "Steam Link not active: bypassing display pipeline (direct launch)"
if (( LOCK_HELD )); then
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
fi
exec "$@"

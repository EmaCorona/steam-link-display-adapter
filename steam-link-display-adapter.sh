#!/usr/bin/env bash
# shellcheck shell=bash
# Steam launch wrapper for Bazzite Game Mode / Gamescope.
# Default target: 1920x1200 @ 60 Hz, 16:10, 60 FPS streaming (fallback); the
# stream geometry is resolved dynamically from the Steam Link client hint when
# STREAM_MODE=auto.
# HANDOFF: environment-specific completion point is intentionally isolated in
# steam-link-display-adapter-hook.sh. Handoff adaptations were applied there on 2026-09-28
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
# 2026-09-29 (spec "Correzione prima connessione"): the detection window in the
# hook is event-driven (pactl subscribe) and no longer requires a previous
# session marker, so the first connection follows the same path as the others.
# The wrapper remains the final guard: it verifies output AND Xwayland #1 before
# GAME_LAUNCH and never trusts an inherited "prepared" claim.
# 2026-09-29 (spec "Risoluzione dinamica"): the geometry is no longer constant.
# After detection the wrapper reads the client capture hint from Steam's host
# log ("Maximum capture: WxH FPS", strictly recent), resolves it against the
# host's advertised modes and drives OUTPUT and Xwayland #1 from the resulting
# runtime TARGET_*; the configured STREAM_* geometry stays as fallback and
# STREAM_MODE=fixed restores the previous behaviour.
# 2026-09-29 (spec "Launch Options --mode"): a per-game target override can be
# given in the Steam Launch Options (--mode auto|WxH). CLI > global
# config > auto; an unavailable fixed mode fails closed before any change.
#
# IMPORTANT:
# - This wrapper is intentionally fail-closed.
# - It NEVER turns the physical display off unless the target Gamescope mode
#   was verified first.
# - The actual Gamescope integration lives in steam-link-display-adapter-hook.sh.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/steam-link-display-adapter-hook.sh"
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter/config"

CONNECTOR='DP-3'
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
STREAM_FPS=60
STREAM_ASPECT='16:10'
STREAM_ALT_REFRESHES='164'
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
LOCAL_WIDTH=3440
LOCAL_HEIGHT=1440
LOCAL_REFRESH=165
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

if [[ -f "$USER_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$USER_CONFIG"
fi

mkdir -p "$STATE_DIR" "$CONFIG_DIR"

# shellcheck disable=SC1091
source "$HOOK"

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
    printf 'steam-link-display-adapter: ERROR: %s\n' "$*" >&2
    return 1
}

lock_acquire() {
    exec 9>"$LOCK_FILE"
    flock -n 9
}

# --- Wrapper CLI (Steam Launch Options) --------------------------------------
#
# steam-link-display-adapter [OPTIONS] %command%
#
# Only the wrapper options BEFORE the game command are consumed; the game
# command (and anything after it) is forwarded verbatim. Supported:
#   --mode auto | WxH            (per-game target override)
#   --help
# A missing/duplicate/unknown option or an invalid --mode value aborts before
# any display or state change.
MODE_SOURCE=''
MODE_SPEC=''
CLI_WIDTH=''
CLI_HEIGHT=''
GAME_ARGS=()

usage() {
    cat >&2 <<'EOF'
Usage:
  steam-link-display-adapter [OPTIONS] %command%

Options:
  --mode auto        Use dynamic resolution based on the Steam Link client.
  --mode WxH         Force the resolution and choose a compatible refresh automatically.
  --help             Show this help.

Examples:
  steam-link-display-adapter --mode auto %command%
  steam-link-display-adapter --mode 1920x1200 %command%
EOF
}

parse_mode_value() {
    # Validate a --mode value and fill the CLI request fields.
    local v=$1
    if [[ "$v" == auto ]]; then
        MODE_SOURCE=auto; MODE_SPEC=auto
        CLI_WIDTH=''; CLI_HEIGHT=''
        return 0
    fi
    # Only "WxH": the refresh is never set from the CLI (it is a resolver
    # concern), so any "@FPS" form is invalid (spec 2026-09-29).
    if [[ "$v" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]]; then
        MODE_SOURCE=cli; MODE_SPEC=$v
        CLI_WIDTH=${BASH_REMATCH[1]}; CLI_HEIGHT=${BASH_REMATCH[2]}
        return 0
    fi
    return 1
}

parse_wrapper_args() {
    local mode_seen=0
    while (( $# > 0 )); do
        case "$1" in
            --help)
                usage; exit 0 ;;
            --mode)
                (( mode_seen )) && { fail "duplicate --mode option"; exit 64; }
                [[ $# -ge 2 ]] || { fail "--mode requires a value"; exit 64; }
                parse_mode_value "$2" || { fail "invalid --mode value: $2"; exit 64; }
                mode_seen=1
                shift 2 ;;
            --mode=*)
                (( mode_seen )) && { fail "duplicate --mode option"; exit 64; }
                parse_mode_value "${1#--mode=}" || { fail "invalid --mode value: ${1#--mode=}"; exit 64; }
                mode_seen=1
                shift ;;
            --)
                shift; break ;;
            -*)
                fail "unknown wrapper option: $1"; exit 64 ;;
            *)
                break ;;
        esac
    done
    GAME_ARGS=("$@")
    [[ ${#GAME_ARGS[@]} -gt 0 ]] || { usage; exit 64; }
}

parse_wrapper_args "$@"

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
# Runtime target resolved from the client hint (spec §10: the configured
# STREAM_* values are never overwritten; they remain the fallback).
CLIENT_WIDTH=''
CLIENT_HEIGHT=''
CLIENT_FPS=''
TARGET_WIDTH=''
TARGET_HEIGHT=''
TARGET_REFRESH=''
TARGET_FPS=''
TARGET_SOURCE=''
TARGET_MODE_SPEC=''

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
    # RESTORING is the transitional phase of the state machine (spec §12).
    if (( SETUP_DONE )); then
        state_write 'RESTORING'
    fi

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
    # The client hint is valid for the current session only (spec §28): drop it
    # so the next stream recomputes its own target from scratch.
    CLIENT_WIDTH=''; CLIENT_HEIGHT=''; CLIENT_FPS=''
    TARGET_WIDTH=''; TARGET_HEIGHT=''; TARGET_REFRESH=''; TARGET_FPS=''; TARGET_SOURCE=''; TARGET_MODE_SPEC=''
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
    [[ "${STREAM_MODE:-auto}" == auto || "${STREAM_MODE:-auto}" == fixed ]] || fail "STREAM_MODE must be 'auto' or 'fixed'"
    [[ "$STREAM_WIDTH" =~ ^[1-9][0-9]*$ ]] || fail "STREAM_WIDTH invalid"
    [[ "$STREAM_HEIGHT" =~ ^[1-9][0-9]*$ ]] || fail "STREAM_HEIGHT invalid"
    [[ "$STREAM_REFRESH" =~ ^[1-9][0-9]*$ ]] || fail "STREAM_REFRESH invalid"
    [[ "$STREAM_FPS" =~ ^[1-9][0-9]*$ ]] || fail "STREAM_FPS invalid"
    [[ "$STREAM_ASPECT" =~ ^[0-9]+:[0-9]+$ ]] || fail "STREAM_ASPECT must be W:H"
    local asp_w asp_h
    asp_w=${STREAM_ASPECT%%:*}; asp_h=${STREAM_ASPECT##*:}
    (( STREAM_WIDTH * asp_h == STREAM_HEIGHT * asp_w )) || fail "STREAM_ASPECT must match STREAM_WIDTH:STREAM_HEIGHT"
    [[ "${STREAM_CAPTURE_HINT_MAX_AGE_SECONDS:-10}" =~ ^[0-9]+$ ]] || fail "STREAM_CAPTURE_HINT_MAX_AGE_SECONDS invalid"
    [[ "${STREAM_NO_COMPATIBLE_FALLBACK:-auto}" =~ ^(auto|never|always)$ ]] || fail "STREAM_NO_COMPATIBLE_FALLBACK must be auto|never|always"
    [[ "${STREAM_ASPECT_TOLERANCE:-5}" =~ ^[0-9]+$ ]] || fail "STREAM_ASPECT_TOLERANCE invalid"
    [[ -n "$CONNECTOR" ]] || fail "CONNECTOR is empty"
    [[ "$MODE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "MODE_TIMEOUT_SECONDS invalid"
    [[ "$STREAM_XWAYLAND_SERVER_INDEX" =~ ^[0-9]+$ ]] || fail "STREAM_XWAYLAND_SERVER_INDEX invalid"
    [[ "$STREAM_XWAYLAND_ALLOW_SUPERRES" =~ ^[01]$ ]] || fail "STREAM_XWAYLAND_ALLOW_SUPERRES must be 0 or 1"
}

resolve_cli_target() {
    # --mode WxH: the CLI fixes only the geometry; the shared resolver picks a
    # compatible refresh. Never uses the configured STREAM_* geometry, and a
    # requested resolution that is unavailable fails closed without
    # substitution.
    TARGET_SOURCE=cli
    TARGET_MODE_SPEC=$MODE_SPEC
    local resolved rw rh rr
    TARGET_WIDTH=$CLI_WIDTH
    TARGET_HEIGHT=$CLI_HEIGHT
    if ! resolved=$(resolve_target_mode "$CLI_WIDTH" "$CLI_HEIGHT" 0); then
        log_event TARGET_MODE_UNAVAILABLE "${CLI_WIDTH}x${CLI_HEIGHT}"
        fail "requested resolution ${CLI_WIDTH}x${CLI_HEIGHT} is not available (fail-closed)"
        return 1
    fi
    read -r rw rh rr <<<"$resolved" || true
    if [[ "$rw" != "$CLI_WIDTH" || "$rh" != "$CLI_HEIGHT" ]]; then
        # The resolver may return a merely aspect-compatible mode; a CLI
        # resolution is a hard constraint, so this is an unavailable mode.
        log_event TARGET_MODE_UNAVAILABLE "${CLI_WIDTH}x${CLI_HEIGHT}"
        fail "requested resolution ${CLI_WIDTH}x${CLI_HEIGHT} is not available (fail-closed)"
        return 1
    fi
    TARGET_REFRESH=${rr:-$STREAM_REFRESH}
    TARGET_FPS=$STREAM_FPS
    log_event CLI_TARGET_MODE "${TARGET_WIDTH}x${TARGET_HEIGHT}"
}

resolve_stream_target() {
    # Turn the mode source into the runtime target (spec §3, §8-§10, §16, §30).
    # Priority: CLI --mode > global config > auto. Sets CLIENT_*/TARGET_* and
    # logs the source. The configured STREAM_* geometry is only ever the
    # fallback (or the fixed target); it is never overwritten.
    local hint resolved policy
    CLIENT_WIDTH=''; CLIENT_HEIGHT=''; CLIENT_FPS=''
    TARGET_WIDTH=''; TARGET_HEIGHT=''; TARGET_REFRESH=''; TARGET_FPS=''; TARGET_SOURCE=''
    TARGET_MODE_SPEC=''

    # CLI override from the Steam Launch Options wins over the global config.
    if [[ "${MODE_SOURCE:-}" == cli ]]; then
        resolve_cli_target || return 1
        log "MODE_SOURCE=cli"
        log "CLI_MODE=${MODE_SPEC:-}"
        log "TARGET_MODE=${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
        log_event TARGET_MODE_RESOLVED "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH} source=cli"
        return 0
    fi

    if [[ "${MODE_SOURCE:-}" == auto ]]; then
        log "MODE_SOURCE=auto"
    elif [[ "${STREAM_MODE:-auto}" == fixed ]]; then
        # Global config fixed (no CLI): equivalent to the previous behaviour and
        # the rollback path; the client hint is not read at all (spec §30).
        TARGET_WIDTH=$STREAM_WIDTH
        TARGET_HEIGHT=$STREAM_HEIGHT
        TARGET_REFRESH=$STREAM_REFRESH
        TARGET_FPS=$STREAM_FPS
        TARGET_SOURCE=fixed
        TARGET_MODE_SPEC="${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_REFRESH}"
        log "MODE_SOURCE=config"
        log "TARGET_MODE=${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
        log_event TARGET_MODE_RESOLVED "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH} source=fixed"
        return 0
    fi

    # Dynamic path (no CLI, or explicit --mode auto).
    if hint=$(get_latest_stream_capture_hint); then
        read -r CLIENT_WIDTH CLIENT_HEIGHT CLIENT_FPS <<<"$hint" || true
        if resolved=$(resolve_target_mode "$CLIENT_WIDTH" "$CLIENT_HEIGHT" "$CLIENT_FPS"); then
            read -r TARGET_WIDTH TARGET_HEIGHT TARGET_REFRESH <<<"$resolved" || true
            [[ -n "$TARGET_REFRESH" ]] || TARGET_REFRESH=$STREAM_REFRESH
            TARGET_FPS=$CLIENT_FPS
            TARGET_SOURCE=steam_capture_hint
            TARGET_MODE_SPEC=auto
            log "Client hint ${CLIENT_WIDTH}x${CLIENT_HEIGHT}@${CLIENT_FPS} -> target ${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
            [[ "${MODE_SOURCE:-}" != auto ]] && log "MODE_SOURCE=auto"
            log "TARGET_MODE=${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
            log_event TARGET_MODE_RESOLVED "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH} source=steam_capture_hint"
            return 0
        fi
        # Valid hint but no aspect-compatible host mode (spec §18).
        policy=${STREAM_NO_COMPATIBLE_FALLBACK:-auto}
        if [[ "$policy" == always ]] || { [[ "$policy" == auto ]] && sl_aspect_compatible "$CLIENT_WIDTH" "$CLIENT_HEIGHT" "$STREAM_WIDTH" "$STREAM_HEIGHT"; }; then
            TARGET_WIDTH=$STREAM_WIDTH
            TARGET_HEIGHT=$STREAM_HEIGHT
            TARGET_REFRESH=$STREAM_REFRESH
            TARGET_FPS=$CLIENT_FPS
            TARGET_SOURCE=fallback
            TARGET_MODE_SPEC=fallback
            log "No aspect-compatible host mode for client ${CLIENT_WIDTH}x${CLIENT_HEIGHT}; using configured fallback"
            log "MODE_SOURCE=fallback"
            log "TARGET_MODE=${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
            log_event TARGET_MODE_RESOLVED "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH} source=fallback"
            return 0
        fi
        fail "no host mode compatible with client ${CLIENT_WIDTH}x${CLIENT_HEIGHT} (fail-closed)"
        return 1
    fi

    # Hint unavailable or stale: configured fallback (spec §8, §28).
    TARGET_WIDTH=$STREAM_WIDTH
    TARGET_HEIGHT=$STREAM_HEIGHT
    TARGET_REFRESH=$STREAM_REFRESH
    TARGET_FPS=$STREAM_FPS
    TARGET_SOURCE=fallback
    TARGET_MODE_SPEC=fallback
    log "MODE_SOURCE=fallback"
    log "TARGET_MODE=${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
    log_event TARGET_MODE_RESOLVED "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH} source=fallback"
    return 0
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

    mode_list_contains "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}" || {
        fail "Gamescope does not currently advertise ${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
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
            printf 'steam-link-display-adapter: another instance is already active\n' >&2
            exit 73
        fi
        LOCK_HELD=1
    fi
    log "Steam Link streaming session detected: running display pipeline"
    log_event STREAM_DETECTED
    validate_config
    resolve_stream_target || exit 1
    precheck
    prepare_stream_mode
    if ! run_game "${GAME_ARGS[@]}"; then
        exit 1
    fi
    exit "$GAME_EXIT_CODE"
fi

log "Steam Link not active: bypassing display pipeline (direct launch)"
if (( LOCK_HELD )); then
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
fi
exec "${GAME_ARGS[@]}"

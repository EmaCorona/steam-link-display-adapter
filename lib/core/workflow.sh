#!/usr/bin/env bash
# shellcheck shell=bash
# Launch workflow (orchestration).
#
# Coordinates the phases and owns nothing but the order:
#   recover -> detect -> validate -> resolve -> precheck -> prepare -> run -> cleanup
# Every concrete interaction with DRM, Xwayland, the state files or the logs is
# delegated to the domain modules.
#
# Steam launch wrapper for Bazzite Game Mode / Gamescope.
# Default target: 1920x1200 @ 60 Hz, 16:10, 60 FPS streaming (fallback); the
# stream geometry is resolved dynamically from the Steam Link client hint when
# STREAM_MODE=auto.
# History of the applied specs (all implemented, none changed by this refactor):
#   2026-09-28  display pipeline only while a Steam Link session is active
#               (steam_link_streaming_active, detection/).
#   2026-09-29  "Sincronizzazione Xwayland #1": the output mode and the Xwayland
#               #1 (game) mode are two distinct states; #1 is synchronized and
#               verified before GAME_LAUNCH (xwayland/).
#   2026-09-29  "Correzione prima connessione": event-driven detection window,
#               no historical marker required (detection/steam-link.sh).
#   2026-09-29  "Risoluzione dinamica": the geometry is resolved from the client
#               capture hint against the advertised host modes (resolution/).
#   2026-09-29  "Launch Options --mode": per-game override, CLI > config > auto.
#
# IMPORTANT:
# - This wrapper is intentionally fail-closed.
# - It NEVER turns the physical display off unless the target Gamescope mode
#   was verified first.
# - The order of the phases below is the behaviour contract; do not reorder.

set -Eeuo pipefail

WRAPPER_START_NS=$(date +%s%N)
XWAYLAND_SYNC_CONFIRMED_NS=0

MODES_EXISTED=${MODES_EXISTED:-0}
SETUP_DONE=0
SCREEN_SLEEP_REQUESTED=0
CLEANUP_DONE=0
GAME_EXIT_CODE=0
BACKUP_TAKEN=0
STALE_STATE_LOADED=0
XWAYLAND_SYNCED=0
LOCK_HELD=0
GAME_PID=
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

sl_wrapper_main() {
    parse_wrapper_args "$@"

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
}

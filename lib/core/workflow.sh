#!/usr/bin/env bash
# shellcheck shell=bash
# Launch workflow (orchestration).
#
# Coordinates the phases and owns nothing but the order:
#   recover -> detect -> validate -> capture -> resolve -> precheck -> prepare -> run -> cleanup
# Every concrete interaction with DRM, Xwayland, the state files or the logs is
# delegated to the domain modules.
#
# Steam launch wrapper for Bazzite Game Mode / Gamescope and KDE Desktop Mode.
# Host-agnostic: the physical display (connector, current mode, description and
# the original Xwayland #1 geometry) is discovered at runtime before any
# modification; the stream geometry is resolved dynamically from the Steam Link
# client hint when STREAM_MODE=auto, with a host-safe fallback to the original
# host mode when the hint is unavailable.
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
#   2026-09-30  "Rimozione modalita' CLI --mode": the per-game --mode override
#               is removed; the only public Launch Option is `%command%` and the
#               target is always resolved by the standard behaviour below.
#   2026-09-29  "Host display agnostic": connector/mode/xwayland discovered at
#               runtime; LOCAL_* are gone and the no-hint fallback is the
#               original host mode (display/profile.sh).
#
# IMPORTANT:
# - This wrapper is intentionally fail-closed.
# - Game Mode only sleeps the physical display after the target Gamescope mode
#   is verified; Desktop Mode leaves the display powered.
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
# Runtime host profile (spec §5-§6): discovered before any mutation, persisted
# in the state file, authoritative for the restore.
HOST_CONNECTOR=''
HOST_DESCRIPTION=''
HOST_ORIGINAL_MODE=''
HOST_ORIGINAL_XWAYLAND_MODE=''

cleanup() {
    local rc=$?

    if (( CLEANUP_DONE )); then
        return "$rc"
    fi
    CLEANUP_DONE=1

    log "Cleanup started (state=$(state_phase || true))"
    if (( SETUP_DONE )); then
        state_write 'RESTORING'
    fi

    if ! display_backend_restore_host_state; then
        log "CRITICAL: display backend restore failed"
    fi

    state_clear
    CLIENT_WIDTH=''; CLIENT_HEIGHT=''; CLIENT_FPS=''
    TARGET_WIDTH=''; TARGET_HEIGHT=''; TARGET_REFRESH=''; TARGET_FPS=''; TARGET_SOURCE=''; TARGET_MODE_SPEC=''
    log "Cleanup finished"

    return "$rc"
}

recover_stale_state() {
    local previous saved_backend verify_mode stale_xwl
    previous=$(state_phase || true)
    [[ -n "$previous" ]] || return 0

    log "Stale state detected: $previous"
    log "Running conservative recovery before starting new game"
    STALE_STATE_LOADED=1

    saved_backend=$(state_field DISPLAY_BACKEND 2>/dev/null || true)
    if [[ -n "$saved_backend" ]]; then
        DISPLAY_BACKEND=$saved_backend
        log "Recovered display backend from state: $DISPLAY_BACKEND"
    elif ! display_backend_detect; then
        log "ERROR: stale state exists but no display backend is available"
        return 1
    fi

    verify_mode=$(original_mode_for_restore)
    stale_xwl=$(original_xwayland_mode_for_restore)
    log "Saved run profile: connector=$(state_field ORIGINAL_CONNECTOR 2>/dev/null || true) mode=${verify_mode:-unavailable} xwayland=${stale_xwl:-unavailable}"

    if ! display_backend_recover_stale_state; then
        return 1
    fi

    state_clear
    log "Stale-state recovery complete"
}

validate_config() {
    [[ "${STREAM_MODE:-auto}" == auto || "${STREAM_MODE:-auto}" == fixed ]] || { fail "STREAM_MODE must be 'auto' or 'fixed'"; return 1; }
    [[ "$STREAM_WIDTH" =~ ^[1-9][0-9]*$ ]] || { fail "STREAM_WIDTH invalid"; return 1; }
    [[ "$STREAM_HEIGHT" =~ ^[1-9][0-9]*$ ]] || { fail "STREAM_HEIGHT invalid"; return 1; }
    [[ "$STREAM_REFRESH" =~ ^[1-9][0-9]*$ ]] || { fail "STREAM_REFRESH invalid"; return 1; }
    [[ "$STREAM_FPS" =~ ^[1-9][0-9]*$ ]] || { fail "STREAM_FPS invalid"; return 1; }
    [[ "$STREAM_ASPECT" =~ ^[0-9]+:[0-9]+$ ]] || { fail "STREAM_ASPECT must be W:H"; return 1; }
    local asp_w asp_h
    asp_w=${STREAM_ASPECT%%:*}; asp_h=${STREAM_ASPECT##*:}
    (( STREAM_WIDTH * asp_h == STREAM_HEIGHT * asp_w )) || { fail "STREAM_ASPECT must match STREAM_WIDTH:STREAM_HEIGHT"; return 1; }
    [[ "${STREAM_CAPTURE_HINT_MAX_AGE_SECONDS:-10}" =~ ^[0-9]+$ ]] || { fail "STREAM_CAPTURE_HINT_MAX_AGE_SECONDS invalid"; return 1; }
    [[ "${STREAM_NO_COMPATIBLE_FALLBACK:-auto}" =~ ^(auto|never|always)$ ]] || { fail "STREAM_NO_COMPATIBLE_FALLBACK must be auto|never|always"; return 1; }
    [[ "${STREAM_ASPECT_TOLERANCE:-5}" =~ ^[0-9]+$ ]] || { fail "STREAM_ASPECT_TOLERANCE invalid"; return 1; }
    [[ "$CONNECTOR" =~ ^[A-Za-z0-9_.-]+$ ]] || { fail "CONNECTOR invalid"; return 1; }
    [[ "$MODE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { fail "MODE_TIMEOUT_SECONDS invalid"; return 1; }
    [[ "$STREAM_XWAYLAND_SERVER_INDEX" =~ ^[0-9]+$ ]] || { fail "STREAM_XWAYLAND_SERVER_INDEX invalid"; return 1; }
    [[ "$STREAM_XWAYLAND_ALLOW_SUPERRES" =~ ^[01]$ ]] || { fail "STREAM_XWAYLAND_ALLOW_SUPERRES must be 0 or 1"; return 1; }
}

resolve_stream_target() {
    # Turn the mode source into the runtime target (spec §3, §8-§10, §16, §30).
    # The only entry point is the standard behaviour: STREAM_MODE=fixed uses the
    # configured geometry, otherwise the target comes from the client capture
    # hint resolved against the host modes. Sets CLIENT_*/TARGET_*. The
    # configured STREAM_* geometry is only ever the fallback for a valid hint
    # with no compatible host mode, or the fixed target; it is never
    # overwritten. Without a usable hint, auto uses the host-safe fallback: the
    # original host mode (spec §26-§27).
    local hint resolved policy
    CLIENT_WIDTH=''; CLIENT_HEIGHT=''; CLIENT_FPS=''
    TARGET_WIDTH=''; TARGET_HEIGHT=''; TARGET_REFRESH=''; TARGET_FPS=''; TARGET_SOURCE=''
    TARGET_MODE_SPEC=''

    if [[ "${STREAM_MODE:-auto}" == fixed ]]; then
        # Global config fixed: the constant behaviour and the rollback path;
        # the client hint is not read at all (spec §30).
        TARGET_WIDTH=$STREAM_WIDTH
        TARGET_HEIGHT=$STREAM_HEIGHT
        TARGET_REFRESH=$STREAM_REFRESH
        TARGET_FPS=$STREAM_FPS
        TARGET_SOURCE=fixed
        TARGET_MODE_SPEC="${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_REFRESH}"
        log "TARGET_MODE=${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
        log_event TARGET_MODE_RESOLVED "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH} source=fixed"
        return 0
    fi

    # Dynamic path (STREAM_MODE=auto, the default).
    if hint=$(get_latest_stream_capture_hint); then
        read -r CLIENT_WIDTH CLIENT_HEIGHT CLIENT_FPS <<<"$hint" || true
        if resolved=$(resolve_target_mode "$CLIENT_WIDTH" "$CLIENT_HEIGHT" "$CLIENT_FPS"); then
            read -r TARGET_WIDTH TARGET_HEIGHT TARGET_REFRESH <<<"$resolved" || true
            [[ -n "$TARGET_REFRESH" ]] || TARGET_REFRESH=$STREAM_REFRESH
            TARGET_FPS=$CLIENT_FPS
            TARGET_SOURCE=steam_capture_hint
            TARGET_MODE_SPEC=auto
            log "Client hint ${CLIENT_WIDTH}x${CLIENT_HEIGHT}@${CLIENT_FPS} -> target ${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
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
            log "TARGET_MODE=${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
            log_event TARGET_MODE_RESOLVED "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH} source=fallback"
            return 0
        fi
        fail "no host mode compatible with client ${CLIENT_WIDTH}x${CLIENT_HEIGHT} (fail-closed)"
        return 1
    fi

    # Hint unavailable or stale: host-safe fallback (spec §26-§27). The target
    # is the original host mode discovered at session start -- never a value
    # that assumes a particular client or display. The configured STREAM_*
    # geometry is not used here: it describes a preference, not the host.
    if [[ -z "${HOST_ORIGINAL_MODE:-}" ]]; then
        fail "host profile not captured; refusing to resolve a target (fail-closed)"
        return 1
    fi
    TARGET_WIDTH=$(mode_width "$HOST_ORIGINAL_MODE")
    TARGET_HEIGHT=$(mode_height "$HOST_ORIGINAL_MODE")
    TARGET_REFRESH=$(mode_refresh "$HOST_ORIGINAL_MODE")
    [[ -n "$TARGET_REFRESH" ]] || TARGET_REFRESH=$STREAM_REFRESH
    TARGET_FPS=$TARGET_REFRESH
    TARGET_SOURCE=host_original
    TARGET_MODE_SPEC=$HOST_ORIGINAL_MODE
    log "Host-safe fallback: client hint unavailable; using the original host mode ${HOST_ORIGINAL_MODE}"
    log "TARGET_MODE=${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
    log_event TARGET_MODE_RESOLVED "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH} source=host_original"
    return 0
}

precheck() {
    display_backend_precheck || return 1

    [[ -n "${ACTIVE_CONNECTOR:-}" ]] || {
        fail "the active display connector was not resolved"
        return 1
    }

    mode_list_contains "${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}" || {
        fail "$(display_backend_name) does not currently advertise ${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
        return 1
    }

    log "Target mode is advertised by $(display_backend_name)"
}



run_game() {
    local now_ns
    now_ns=$(date +%s%N)
    # Gamescope requires explicit Xwayland #1 synchronization. Desktop Mode
    # has no Gamescope Xwayland control contract, so the invariant is scoped to
    # the backend that provides it.
    if display_backend_supports_xwayland; then
        if (( XWAYLAND_SYNC_CONFIRMED_NS == 0 || now_ns <= XWAYLAND_SYNC_CONFIRMED_NS )); then
            fail "refusing to launch: XWAYLAND1_SYNC_CONFIRMED must precede GAME_LAUNCH"
            return 1
        fi
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

    # Detect the runtime display backend before deciding whether the display
    # pipeline can be used. Gamescope remains first; KDE Desktop Mode is a
    # separate backend with the same lifecycle contract.
    if [[ ! -f "$STATE_FILE" ]]; then
        if ! display_backend_detect; then
            log "No supported display backend detected: bypassing display pipeline"
            exec "${GAME_ARGS[@]}"
        fi
    fi

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

    # A successful stale recovery clears the state and hands control back to
    # the current session. Re-detect the backend so a transition between
    # Game Mode and Desktop Mode cannot inherit the old backend selection.
    if [[ ! -f "$STATE_FILE" ]]; then
        if ! display_backend_detect; then
            log "No supported display backend detected after recovery: bypassing display pipeline"
            exec "${GAME_ARGS[@]}"
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
        # Host profile discovery: before any mutation (spec §10).
        capture_host_profile || exit 1
        resolve_stream_target || exit 1
        precheck
        display_backend_prepare_stream
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

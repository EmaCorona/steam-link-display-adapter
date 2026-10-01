#!/usr/bin/env bash
# shellcheck shell=bash
# Runtime display backend selection and the common display lifecycle facade.
#
# The workflow depends on this contract, never on a concrete session:
#   gamescope -> Bazzite Game Mode / Gamescope  (display/gamescope.sh)
#   desktop   -> KDE Plasma Desktop Mode        (display/desktop.sh)
#
# Adding a backend means implementing these operations in its own module; the
# workflow and this facade need no per-backend conditionals.
set -Eeuo pipefail

DISPLAY_BACKEND=''

display_backend_detect() {
    if _sl_gamescope_session_available; then
        DISPLAY_BACKEND='gamescope'
        log "Display backend detected: Gamescope"
        log_event DISPLAY_BACKEND_DETECTED gamescope
        return 0
    fi

    if desktop_backend_available; then
        DISPLAY_BACKEND='desktop'
        log "Display backend detected: Desktop/KScreen"
        log_event DISPLAY_BACKEND_DETECTED desktop
        return 0
    fi

    DISPLAY_BACKEND=''
    log_event DISPLAY_BACKEND_UNAVAILABLE
    return 1
}

display_backend_name() {
    printf '%s\n' "${DISPLAY_BACKEND:-unknown}"
}

display_backend_is() {
    [[ "${DISPLAY_BACKEND:-}" == "$1" ]]
}

display_backend_supports_xwayland() {
    [[ "${DISPLAY_BACKEND:-}" == gamescope ]]
}

display_backend_requires_host_mode() {
    # True when the stream geometry must exist among the host display modes.
    # The Desktop virtual output is created at the requested geometry, so it is
    # independent of the physical mode set (spec: resolution model).
    if display_backend_is desktop && desktop_virtual_mode_selected; then
        return 1
    fi
    return 0
}

display_backend_mode_supported() {
    local mode=$1
    if display_backend_requires_host_mode; then
        mode_list_contains "$mode"
        return
    fi
    [[ "$mode" =~ ^[0-9]+x[0-9]+@[0-9]+$ ]]
}

display_backend_precheck() {
    case "${DISPLAY_BACKEND:-}" in
        gamescope)
            require_cmd gamescopectl || return 1
            require_cmd xprop || return 1
            require_cmd xdpyinfo || return 1
            require_cmd journalctl || return 1
            [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]] || {
                fail "DISPLAY/GAMESCOPE_DISPLAY is not set"
                return 1
            }
            ;;
        desktop)
            require_cmd kscreen-doctor || return 1
            ;;
        *)
            fail "no display backend selected"
            return 1
            ;;
    esac

    require_cmd flock || return 1
}

display_backend_prepare_stream() {
    case "${DISPLAY_BACKEND:-}" in
        gamescope) gamescope_prepare_stream_mode ;;
        desktop) desktop_prepare_stream_mode ;;
        *) fail "no display backend selected"; return 1 ;;
    esac
}

display_backend_apply_monitor_power() {
    local phase
    phase=$(state_phase 2>/dev/null || printf 'STREAMING')

    case "${MONITOR_POWER_MODE:-off}" in
        off)
            # Persist the intent before issuing the power-off request. If the
            # process is interrupted immediately after this point, the next
            # invocation can conservatively wake the display during recovery.
            SCREEN_SLEEP_REQUESTED=1
            state_write "${phase:-STREAMING}"
            log "Monitor policy: off (backend=$(display_backend_name))"
            if ! screen_sleep; then
                fail "failed to turn the monitor off during Steam Link streaming"
                return 1
            fi
            log_event MONITOR_POWER_APPLIED off
            log "Monitor turned off for Steam Link streaming"
            ;;
        on)
            SCREEN_SLEEP_REQUESTED=0
            state_write "${phase:-STREAMING}"
            log_event MONITOR_POWER_APPLIED on
            log "Monitor kept on for Steam Link streaming"
            ;;
        *)
            fail "invalid monitor power mode: ${MONITOR_POWER_MODE:-}"
            return 1
            ;;
    esac
}

display_backend_restore_monitor_power() {
    if (( ! SCREEN_SLEEP_REQUESTED )); then
        return 0
    fi

    if screen_wake; then
        SCREEN_SLEEP_REQUESTED=0
        log_event MONITOR_POWER_RESTORED on
        log "Monitor wake requested during cleanup/recovery"
        return 0
    fi

    log "CRITICAL: failed to wake the monitor during cleanup/recovery"
    return 1
}

display_backend_restore_host_state() {
    local rc=0
    if ! display_backend_restore_monitor_power; then
        rc=1
    fi

    case "${DISPLAY_BACKEND:-}" in
        gamescope) gamescope_restore_host_state || rc=1 ;;
        desktop) desktop_restore_host_state || rc=1 ;;
        *) fail "no display backend selected"; return 1 ;;
    esac
    return "$rc"
}

display_backend_recover_stale_state() {
    local rc=0
    if ! display_backend_restore_monitor_power; then
        rc=1
    fi

    case "${DISPLAY_BACKEND:-}" in
        gamescope) gamescope_recover_stale_state || rc=1 ;;
        desktop) desktop_recover_stale_state || rc=1 ;;
        *) fail "no display backend selected"; return 1 ;;
    esac
    return "$rc"
}

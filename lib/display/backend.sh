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

display_backend_restore_host_state() {
    case "${DISPLAY_BACKEND:-}" in
        gamescope) gamescope_restore_host_state ;;
        desktop) desktop_restore_host_state ;;
        *) fail "no display backend selected"; return 1 ;;
    esac
}

display_backend_recover_stale_state() {
    case "${DISPLAY_BACKEND:-}" in
        gamescope) gamescope_recover_stale_state ;;
        desktop) desktop_recover_stale_state ;;
        *) fail "no display backend selected"; return 1 ;;
    esac
}

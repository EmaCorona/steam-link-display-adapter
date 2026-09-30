#!/usr/bin/env bash
# shellcheck shell=bash
# Display/DRM mode state: discovery, current mode, switch, verification and the
# external-screen controls.
#
# Handoff H2/H3/H7 adaptations for this Bazzite build (gamescope 3.16.28-ogc3+,
# measured 2026-09-28):
#   - mode re-poll via `gamescopectl backend_set_dirty`; the
#     GAMESCOPE_DISPLAY_MODE_NUDGE X atom is not exposed by this build.
#   - current-mode readback from the user journal: last "drm: selecting mode
#     WxH@RHz". X screen geometry and the refresh feedback atom do not represent
#     the DRM mode the session is actually scanning.
#   - mode list from GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL when present, else the
#     kernel ModeDB of the connector; the exact refresh is enforced by the
#     post-switch verification (before any screen sleep).
#   - target verification accepts the display's re-picked refresh for the same
#     resolution (dynamic modes; observed 1920x1200@60Hz -> @164Hz): same
#     width + same height = same stream geometry, determined dynamically,
#     never from a configured list (host display agnostic spec §21-§22).
#   - host mode queries always use the runtime connector (spec §19-§20), never
#     a hardcoded or statically configured one.

set -Eeuo pipefail

mode_geometry() {
    # "WxH@R" -> "WxH" ("WxH" unchanged).
    printf '%s\n' "${1%@*}"
}

mode_width() {
    local g
    g=$(mode_geometry "$1")
    printf '%s\n' "${g%%x*}"
}

mode_height() {
    local g
    g=$(mode_geometry "$1")
    printf '%s\n' "${g#*x}"
}

mode_refresh() {
    # "WxH@R" -> "R"; empty (exit 0) when no refresh is present.
    if [[ "$1" == *@* ]]; then
        printf '%s\n' "${1##*@}"
    fi
    return 0
}

get_gamescope_mode_list() {
    local raw list
    raw=$(xprop_root_get GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL) || return 1
    # Example: GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL(STRING) = "3440x1440@165 1920x1200@60"
    list=$(sed -n 's/.*= *"\(.*\)"/\1/p' <<<"$raw")
    [[ -n "$list" ]] || return 1
    printf '%s\n' "$list"
}

gamescope_get_host_mode_list() {
    # Mode candidates the host really advertises, one "WxH" or "WxH@R" per line.
    # Sources in order (spec §12): Gamescope X atom, modes.cfg, kernel ModeDB.
    local list line mode found=0 modes_file f
    if list=$(get_gamescope_mode_list) && [[ -n "$list" ]]; then
        printf '%s\n' "$list" | tr ' ' '\n' | grep -E '^[0-9]+x[0-9]+(@[0-9]+)?$' | sort -u
        return 0
    fi
    modes_file="${MODES_FILE:-$HOME/.config/gamescope/modes.cfg}"
    if [[ -f "$modes_file" ]]; then
        while IFS= read -r line; do
            mode=$(sed -n 's/^[^:]*:\([0-9]\+x[0-9]\+@[0-9]\+\).*/\1/p' <<<"$line")
            [[ -n "$mode" ]] && { printf '%s\n' "$mode"; found=1; }
        done <"$modes_file"
    fi
    for f in ${DRM_MODES_GLOB:-$(drm_modes_default_glob)}; do
        [[ -f "$f" ]] || continue
        while IFS= read -r mode; do
            [[ "$mode" =~ ^[0-9]+x[0-9]+$ ]] && { printf '%s\n' "$mode"; found=1; }
        done <"$f"
    done
    (( found )) && return 0
    return 1
}

gamescope_mode_list_contains() {
    local wanted=$1 list line mode res f modes_file
    if list=$(get_gamescope_mode_list) && [[ -n "$list" ]]; then
        tr ' ' '\n' <<<"$list" | grep -Fxq "$wanted"
        return $?
    fi
    # No X atom on this build: check modes.cfg, then fall back to the kernel
    # ModeDB of the connector. The refresh cannot be read back from the ModeDB;
    # the exact target refresh is proven by the post-switch verification before
    # any screen sleep.
    modes_file="${MODES_FILE:-$HOME/.config/gamescope/modes.cfg}"
    if [[ -f "$modes_file" ]]; then
        while IFS= read -r line; do
            mode=$(sed -n 's/^[^:]*:\([0-9]\+x[0-9]\+@[0-9]\+\).*/\1/p' <<<"$line")
            [[ "$mode" == "$wanted" ]] && return 0
        done <"$modes_file"
    fi
    log "mode list: Gamescope X atom unavailable; checking kernel ModeDB for $(host_connector)"
    res=${wanted%@*}
    for f in ${DRM_MODES_GLOB:-$(drm_modes_default_glob)}; do
        [[ -f "$f" ]] || continue
        if grep -qx -- "$res" "$f"; then
            return 0
        fi
    done
    return 1
}

gamescope_get_current_mode() {
    require_cmd journalctl || return 1
    local line mode
    # Read the DRM mode from the session log. X geometry/refresh atoms are not
    # reliable for this on the current build.
    line=$(journalctl --user -b --no-pager -g 'selecting mode [0-9]' 2>/dev/null | tail -n 1 || true)
    [[ -n "$line" ]] || return 1
    mode=$(sed -n 's/.*selecting mode \([0-9]\+x[0-9]\+\)@\([0-9]\+\)Hz.*/\1@\2/p' <<<"$line")
    [[ -n "$mode" ]] || return 1
    printf '%s\n' "$mode"
}

gamescope_is_target_mode_active() {
    local current res tw th cw ch
    res="${TARGET_WIDTH:-$STREAM_WIDTH}x${TARGET_HEIGHT:-$STREAM_HEIGHT}"
    current=$(get_current_mode 2>/dev/null || true)
    [[ -n "$current" ]] || return 1
    if [[ "$current" == "${res}@${TARGET_REFRESH:-$STREAM_REFRESH}" ]]; then
        return 0
    fi
    # The refresh is not a constant: with dynamic external modes enabled
    # gamescope re-picks the display's refresh for the same resolution right
    # after the switch (measured 2026-09-29: 1920x1200@60Hz -> @164Hz within
    # ~1s). The property verified is the stream geometry (spec §22): same
    # width + same height is accepted, a different resolution never is,
    # whatever its refresh. The valid refreshes are therefore determined
    # dynamically from the mode gamescope really selects, with no configured
    # list (spec §21).
    tw=${res%%x*}; th=${res#*x}
    cw=${current%%x*}; ch=${current#*x}; ch=${ch%%@*}
    [[ "$cw" == "$tw" && "$ch" == "$th" ]]
}

gamescope_is_original_mode_active() {
    # True when the DRM mode is the one the display must go back to (spec §13):
    # the original host mode captured at session start, recovered from the
    # state file, or passed explicitly by the caller.
    local expected=${1:-${HOST_ORIGINAL_MODE:-}}
    [[ -n "$expected" ]] || return 1
    [[ "$(get_current_mode 2>/dev/null || true)" == "$expected" ]]
}

gamescope_set_dynamic_modes_allowed() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl drm_allow_dynamic_modes_for_external_display "$1" >/dev/null
}

gamescope_screen_sleep() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl drm_sleep_external_screen 1 >/dev/null
}

gamescope_screen_wake() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl drm_sleep_external_screen 0 >/dev/null
}

gamescope_nudge_mode() {
    require_cmd gamescopectl || return 1
    # Re-poll the backend so gamescope re-runs connector setup and picks up the
    # saved mode written to modes.cfg. Polling/verification always follows; a
    # nudge alone is never considered sufficient.
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl backend_set_dirty >/dev/null
}

gamescope_wait_for_target_mode() {
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if is_target_mode_active; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

gamescope_wait_for_original_mode() {
    local want=${1:-${HOST_ORIGINAL_MODE:-}} deadline
    [[ -n "$want" ]] || return 1
    deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if is_original_mode_active "$want"; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}


# Backend-neutral display operations. The Gamescope implementation above is
# retained unchanged behind this dispatch layer; Desktop Mode is implemented
# by the KDE/KScreen backend.
get_host_mode_list() {
    if display_backend_is desktop; then desktop_get_host_mode_list; else gamescope_get_host_mode_list; fi
}

mode_list_contains() {
    if display_backend_is desktop; then desktop_mode_list_contains "$1"; else gamescope_mode_list_contains "$1"; fi
}

get_current_mode() {
    if display_backend_is desktop; then desktop_get_current_mode; else gamescope_get_current_mode; fi
}

is_target_mode_active() {
    if display_backend_is desktop; then desktop_is_target_mode_active; else gamescope_is_target_mode_active; fi
}

is_original_mode_active() {
    if display_backend_is desktop; then
        local expected=${1:-${HOST_ORIGINAL_MODE:-}}
        [[ -n "$expected" ]] || return 1
        local current
        current=$(desktop_get_current_mode 2>/dev/null || true)
        [[ "$current" == "$expected" ]]
    else
        gamescope_is_original_mode_active "$@"
    fi
}

set_dynamic_modes_allowed() {
    if display_backend_is desktop; then return 0; else gamescope_set_dynamic_modes_allowed "$@"; fi
}

screen_sleep() {
    if display_backend_is desktop; then return 0; else gamescope_screen_sleep "$@"; fi
}

screen_wake() {
    if display_backend_is desktop; then return 0; else gamescope_screen_wake "$@"; fi
}

nudge_mode() {
    if display_backend_is desktop; then return 0; else gamescope_nudge_mode "$@"; fi
}

wait_for_target_mode() {
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if is_target_mode_active; then return 0; fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_original_mode() {
    local want=${1:-${HOST_ORIGINAL_MODE:-}} deadline
    [[ -n "$want" ]] || return 1
    local current
    if display_backend_is desktop; then
        desktop_wait_for_original_mode "$want"
    else
        gamescope_wait_for_original_mode "$want"
    fi
}

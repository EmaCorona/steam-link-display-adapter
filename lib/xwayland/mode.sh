#!/usr/bin/env bash
# shellcheck shell=bash
#
# Mechanism measured 2026-09-29 on gamescope 3.16.28-ogc3+ (nested instance,
# --xwayland-count 2, Desktop Mode) and valid for the Gaming Mode session:
#
#   * every Xwayland root carries GAMESCOPE_XWAYLAND_SERVER_ID = its Gamescope
#     server index, so the DISPLAY <-> index mapping is discovered at runtime and
#     never assumed: the numeric display does NOT equal the index (probe:
#     DISPLAY :1 -> id 0, DISPLAY :2 -> id 1).
#   * writing the root property
#         GAMESCOPE_XWAYLAND_MODE_CONTROL = [server_idx, width, height, allowSuperRes]
#     (xprop -f ... 32c -set "1, 1024, 768, 0") makes gamescope call
#         wlserver_set_xwayland_server_mode(server_idx, w, h, g_nOutputRefresh)
#     (journal: "wlserver: Updating mode for xwayland server #1: 1024x768@60")
#     and the target root window really changes size. The write works on the
#     server's own root and on the UI server's root (gamescope routes by idx).
#   * gamescope deletes the property once handled, so the property readback is
#     never the confirmation -- the target root-window geometry is.
#
# `xprop` needs the right DISPLAY (and XAUTHORITY, inherited from the launch
# environment) for each candidate server.

declare -A XWAYLAND_DISPLAY_CACHE=()

xwayland_candidate_displays() {
    local s i d
    printf '%s\n' "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}"
    printf '%s\n' "${DISPLAY:-}"
    for s in /tmp/.X11-unix/X*; do
        [[ -e "$s" ]] || continue
        printf ':%s\n' "${s##*X}"
    done
    for d in ${XWAYLAND_EXTRA_DISPLAYS:-}; do
        [[ -n "$d" ]] && printf '%s\n' "$d"
    done
    for ((i = 0; i <= ${XWAYLAND_SCAN_MAX:-9}; i++)); do
        printf ':%s\n' "$i"
    done
    return 0
}

xwayland_server_id_for_display() {
    local display=$1 raw id
    [[ -n "$display" ]] || return 1
    raw=$(DISPLAY="$display" xprop -root GAMESCOPE_XWAYLAND_SERVER_ID 2>/dev/null) || return 1
    id=$(sed -n 's/.*= *\([0-9][0-9]*\).*/\1/p' <<<"$raw")
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$id"
}

xwayland_display_for_server() {
    local want=$1 display id seen=' '
    if [[ -n "${XWAYLAND_DISPLAY_CACHE[$want]:-}" ]]; then
        printf '%s\n' "${XWAYLAND_DISPLAY_CACHE[$want]}"
        return 0
    fi
    while IFS= read -r display; do
        [[ -n "$display" ]] || continue
        [[ "$seen" == *" $display "* ]] && continue
        seen+="$display "
        id=$(xwayland_server_id_for_display "$display") || continue
        XWAYLAND_DISPLAY_CACHE[$id]=$display
        if [[ "$id" == "$want" ]]; then
            printf '%s\n' "$display"
            return 0
        fi
    done < <(xwayland_candidate_displays)
    return 1
}

get_xwayland_root_size() {
    local display=$1 size
    require_cmd xdpyinfo || return 1
    [[ -n "$display" ]] || return 1
    size=$(DISPLAY="$display" xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
    [[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || return 1
    printf '%s\n' "$size"
}

get_xwayland_server_mode() {
    local display
    display=$(xwayland_display_for_server "$1") || return 1
    get_xwayland_root_size "$display"
}

xwayland_server_present() {
    xwayland_display_for_server "$1" >/dev/null 2>&1
}

set_xwayland_server_mode() {
    local idx=$1 width=$2 height=$3 allow_super_res=${4:-0} display
    require_cmd xprop || return 1
    display=$(xwayland_display_for_server "$idx") \
        || display=$(xwayland_display_for_server 0) \
        || display="${GAMESCOPE_DISPLAY:-${DISPLAY:-}}"
    [[ -n "$display" ]] || return 1
    DISPLAY="$display" xprop -root -f GAMESCOPE_XWAYLAND_MODE_CONTROL 32c \
        -set GAMESCOPE_XWAYLAND_MODE_CONTROL "${idx}, ${width}, ${height}, ${allow_super_res}" \
        >/dev/null 2>&1
}

set_stream_xwayland_mode() {
    # Uses the runtime target resolved from the client hint, not the static
    # stream config (spec §21-§22): Xwayland #1 must match the output geometry.
    set_xwayland_server_mode "${STREAM_XWAYLAND_SERVER_INDEX:-1}" \
        "${TARGET_WIDTH:-$STREAM_WIDTH}" "${TARGET_HEIGHT:-$STREAM_HEIGHT}" "${STREAM_XWAYLAND_ALLOW_SUPERRES:-0}"
}

verify_stream_xwayland_mode() {
    local want="${TARGET_WIDTH:-$STREAM_WIDTH}x${TARGET_HEIGHT:-$STREAM_HEIGHT}" got
    got=$(get_xwayland_server_mode "${STREAM_XWAYLAND_SERVER_INDEX:-1}" 2>/dev/null || true)
    [[ "$got" == "$want" ]]
}

wait_for_stream_xwayland_mode() {
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if verify_stream_xwayland_mode; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

restore_stream_xwayland_mode() {
    local idx="${STREAM_XWAYLAND_SERVER_INDEX:-1}"
    local want="${LOCAL_WIDTH}x${LOCAL_HEIGHT}" deadline got
    xwayland_display_for_server "$idx" >/dev/null 2>&1 || return 0
    set_xwayland_server_mode "$idx" "$LOCAL_WIDTH" "$LOCAL_HEIGHT" 0 || return 1
    deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        got=$(get_xwayland_server_mode "$idx" 2>/dev/null || true)
        [[ "$got" == "$want" ]] && return 0
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

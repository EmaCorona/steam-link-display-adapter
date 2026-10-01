#!/usr/bin/env bash
# shellcheck shell=bash
# Gamescope session / X atom access (read-only).

set -Eeuo pipefail

_sl_gamescope_session_available() {
    # True when a Gamescope session is reachable. Used only as the negative gate
    # for the detection window in Desktop Mode (spec §17: immediate direct
    # launch); it is never taken as proof of a Steam Link session (spec §8).
    command -v gamescopectl >/dev/null 2>&1 || return 1
    # Capture the output instead of piping into `grep -q`: with `set -o
    # pipefail` an early grep exit can kill the producer with SIGPIPE and fail
    # the whole pipeline, which would report "no Gamescope session" at random.
    local out
    out=$(GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl 2>/dev/null || true)
    [[ "$out" == *'Connector Name:'* ]]
}

xprop_root_get() {
    local atom=$1
    [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]] || return 1
    DISPLAY="${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" xprop -root "$atom" 2>/dev/null
}

get_gamescope_info() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl 2>/dev/null
}

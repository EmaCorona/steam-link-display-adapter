#!/usr/bin/env bash
# shellcheck shell=bash
# Read-only environment report (orchestration).
#
# It does not modify display state or files, and it does not depend on the
# pipeline: it only reports what the environment currently exposes, including
# the host display profile discovered at runtime (host display agnostic spec
# §31), so it stays useful on any unknown machine.

sl_verify_environment_main() {
    printf '%s\n' '=== Steam Link Display Environment ==='
    printf 'DATE: %s\n' "$(date -Is)"
    printf 'USER: %s\n' "${USER:-unknown}"
    printf 'DISPLAY: %s\n' "${DISPLAY:-<unset>}"
    printf 'GAMESCOPE_WAYLAND_DISPLAY: %s\n' "$GAMESCOPE_WAYLAND_DISPLAY"

    printf '\n--- Configuration ---\n'
    printf 'Connector preference: %s\n' "$CONNECTOR"
    printf 'Stream mode: %s\n' "$STREAM_MODE"
    printf 'Fallback/fixed mode: %sx%s@%s\n' "$STREAM_WIDTH" "$STREAM_HEIGHT" "$STREAM_REFRESH"
    printf 'Steam host log: %s\n' "${STEAM_STREAM_LOG:-$HOME/.local/share/Steam/logs/streaming_log.txt}"

    printf '\n--- Host display (runtime discovery) ---\n'
    local connector description current xwl idx
    idx=${STREAM_XWAYLAND_SERVER_INDEX:-1}
    connector=$(get_connector_name 2>/dev/null || true)
    description=$(get_display_description 2>/dev/null || true)
    current=$(get_current_mode 2>/dev/null || true)
    xwl=$(get_xwayland_server_mode "$idx" 2>/dev/null || true)
    printf 'Connector: %s\n' "${connector:-unavailable}"
    printf 'Description: %s\n' "${description:-unavailable}"
    printf 'Current mode: %s\n' "${current:-unavailable}"
    printf 'Xwayland #%s: %s\n' "$idx" "${xwl:-unavailable}"

    printf '\n--- Host modes ---\n'
    local modes
    modes=$(get_host_mode_list 2>/dev/null || true)
    if [[ -n "$modes" ]]; then
        printf '%s\n' "$modes"
    else
        printf '%s\n' 'No host mode list available.'
    fi

    printf '\n--- Commands ---\n'
    for c in gamescopectl xprop xdpyinfo drm_info; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '%-15s %s\n' "$c" "$(command -v "$c")"
        else
            printf '%-15s MISSING\n' "$c"
        fi
    done

    printf '\n--- Steam client capture hint ---\n'
    if [[ -f "${STEAM_STREAM_LOG:-$HOME/.local/share/Steam/logs/streaming_log.txt}" ]]; then
        grep -a 'Maximum capture:' "${STEAM_STREAM_LOG:-$HOME/.local/share/Steam/logs/streaming_log.txt}" 2>/dev/null | tail -n 3 || true
    else
        printf '%s\n' 'Steam host log not found.'
    fi

    printf '\n--- Gamescope info ---\n'
    gamescopectl 2>&1 || true

    printf '\n--- Gamescope X atoms ---\n'
    if [[ -n "${DISPLAY:-}" ]]; then
        xprop -root GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL 2>&1 || true
        xprop -root GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK 2>&1 || true
        xprop -root GAMESCOPE_DISPLAY_IS_EXTERNAL 2>&1 || true
        xprop -root GAMESCOPE_DISPLAY_MODE_NUDGE 2>&1 || true
    else
        printf '%s\n' 'DISPLAY unset: X atom inspection skipped.'
    fi

    printf '\n--- X screen size ---\n'
    if command -v xdpyinfo >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
        xdpyinfo 2>&1 | awk '/dimensions:/ {print; exit}' || true
    fi

    printf '\n--- DRM connectors ---\n'
    local runtime_connector p
    runtime_connector=$(get_connector_name 2>/dev/null || true)
    if [[ -z "$runtime_connector" && "$CONNECTOR" != auto ]]; then
        runtime_connector=$CONNECTOR
    fi
    for p in /sys/class/drm/card*-*; do
        [[ -f "$p/status" ]] || continue
        printf '%s: status=%s\n' "$(basename "$p")" "$(cat "$p/status")"
        if [[ -n "$runtime_connector" && "$(basename "$p")" == *"-$runtime_connector" ]]; then
            printf 'modes:\n'
            cat "$p/modes" 2>/dev/null || true
        fi
    done

    printf '\n=== END ===\n'
}

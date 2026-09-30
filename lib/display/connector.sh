#!/usr/bin/env bash
# shellcheck shell=bash
# Connector / display identification and runtime connector resolution
# (host display agnostic spec §7-§8).

set -Eeuo pipefail

get_connector_name() {
    if display_backend_is desktop; then
        desktop_get_connector_name
    else
        get_gamescope_info | awk -F': ' '/Connector Name:/ {print $2; exit}'
    fi
}

get_display_make() {
    get_gamescope_info | awk -F': ' '/Display Make:/ {print $2; exit}'
}

get_display_model() {
    get_gamescope_info | awk -F': ' '/Display Model:/ {print $2; exit}'
}

get_display_description() {
    if display_backend_is desktop; then
        desktop_get_display_description
        return
    fi

    local make model
    make=$(get_display_make || true)
    model=$(get_display_model || true)
    [[ -n "$make" && -n "$model" ]] || return 1
    printf '%s %s' "$make" "$model"
}

resolve_active_connector() {
    if display_backend_is desktop; then
        desktop_resolve_active_connector
        return
    fi

    local gc
    gc=$(get_connector_name || true)
    if [[ -z "$gc" ]]; then
        fail "Gamescope connector not reachable via gamescopectl (is the Gaming Mode session running?)"
        return 1
    fi
    if [[ "${CONNECTOR:-auto}" != auto && "$gc" != "$CONNECTOR" ]]; then
        fail "Gamescope connector is '$gc', expected '$CONNECTOR'"
        return 1
    fi
    log "Gamescope connector verified: $gc"
    printf '%s\n' "$gc"
}

host_connector() {
    # Connector used for host-mode queries: runtime connector once the host
    # profile is captured; Desktop Mode can discover it lazily for standalone
    # backend operations.
    if display_backend_is desktop; then
        if [[ -n "${ACTIVE_CONNECTOR:-}" ]]; then
            printf '%s\n' "$ACTIVE_CONNECTOR"
        else
            desktop_get_connector_name
        fi
        return
    fi
    printf '%s\n' "${ACTIVE_CONNECTOR:-${CONNECTOR:-auto}}"
}

drm_modes_default_glob() {
    # Default kernel ModeDB glob for the runtime connector (spec §20).
    printf '/sys/class/drm/card*-%s/modes\n' "$(host_connector)"
}

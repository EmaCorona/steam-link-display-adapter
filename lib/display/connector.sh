#!/usr/bin/env bash
# shellcheck shell=bash
# Connector / display identification and runtime connector resolution
# (host display agnostic spec §7-§8).

set -Eeuo pipefail

get_connector_name() {
    get_gamescope_info | awk -F': ' '/Connector Name:/ {print $2; exit}'
}

get_display_make() {
    get_gamescope_info | awk -F': ' '/Display Make:/ {print $2; exit}'
}

get_display_model() {
    get_gamescope_info | awk -F': ' '/Display Model:/ {print $2; exit}'
}

get_display_description() {
    local make model
    make=$(get_display_make || true)
    model=$(get_display_model || true)
    [[ -n "$make" && -n "$model" ]] || return 1
    printf '%s %s' "$make" "$model"
}

resolve_active_connector() {
    # The source of truth for the connector is the Gamescope session (spec §7).
    # CONNECTOR=auto (default) follows it; a manual override must match it,
    # otherwise the wrapper fails closed before any display change (spec §8).
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
    # Connector used for host-mode queries (spec §19-§20): the runtime one once
    # the host profile was captured; the configured value otherwise (standalone
    # helpers). Never a hardcoded connector.
    printf '%s\n' "${ACTIVE_CONNECTOR:-${CONNECTOR:-auto}}"
}

drm_modes_default_glob() {
    # Default kernel ModeDB glob for the runtime connector (spec §20).
    printf '/sys/class/drm/card*-%s/modes\n' "$(host_connector)"
}

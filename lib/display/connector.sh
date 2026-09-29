#!/usr/bin/env bash
# shellcheck shell=bash
# Connector / display identification.

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

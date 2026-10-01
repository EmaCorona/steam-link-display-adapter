#!/usr/bin/env bash
# shellcheck shell=bash
# KDE Plasma Desktop Mode display backend.
#
# Desktop Mode on Bazzite KDE runs through the desktop compositor rather than
# Gamescope. KScreen is the compositor-aware control plane for output modes.
set -Eeuo pipefail

desktop_kscreen_outputs() {
    TERM=dumb NO_COLOR=1 kscreen-doctor -o 2>/dev/null |
        sed -E 's/\x1B\[[0-9;]*m//g'
}

desktop_backend_available() {
    command -v kscreen-doctor >/dev/null 2>&1 || return 1
    # No `| grep -q` pipeline: under `pipefail` an early grep exit can SIGPIPE
    # the producer and fail the check at random.
    local out
    out=$(desktop_kscreen_outputs || true)
    [[ "$out" == Output:* || "$out" == *$'\n'Output:* ]]
}

_desktop_output_block() {
    local connector=$1 info
    info=$(desktop_kscreen_outputs) || return 1
    awk -v want="$connector" '
        /^Output:/ {
            if (in_block) exit
            in_block=($3 == want)
            if (in_block) print
            next
        }
        in_block { print }
    ' <<<"$info"
}

desktop_get_primary_connector() {
    local info primary
    info=$(desktop_kscreen_outputs) || return 1
    primary=$(awk '
        /^Output:/ && ($0 ~ /(^|[[:space:]])primary([[:space:]]|$)/) {
            print $3
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' <<<"$info") || return 1
    printf '%s\n' "$primary"
}

desktop_get_connector_name() {
    local info connector
    info=$(desktop_kscreen_outputs) || return 1

    if [[ "${CONNECTOR:-auto}" != auto ]]; then
        connector=$(awk -v want="$CONNECTOR" '
            /^Output:/ && $3 == want { print $3; found=1; exit }
            END { if (!found) exit 1 }
        ' <<<"$info") || return 1
        printf '%s\n' "$connector"
        return 0
    fi

    awk '
        function choose() {
            if (name != "" && enabled && connected && priority ~ /^[0-9]+$/ && priority < best) {
                best=priority
                selected=name
            }
        }
        BEGIN { best=999999; name=""; enabled=0; connected=0; priority="" }
        /^Output:/ {
            choose()
            name=$3
            enabled=($0 ~ /(^|[[:space:]])enabled([[:space:]]|$)/)
            connected=($0 ~ /(^|[[:space:]])connected([[:space:]]|$)/)
            priority=""
            if (match($0, /priority[[:space:]]+[0-9]+/)) {
                priority=substr($0, RSTART) 
                sub(/^priority[[:space:]]+/, "", priority)
                sub(/[[:space:]].*$/, "", priority)
            }
            next
        }
        /^[[:space:]]+enabled[[:space:]]*$/ { enabled=1; next }
        /^[[:space:]]+connected[[:space:]]*$/ { connected=1; next }
        /^[[:space:]]+priority[[:space:]]+[0-9]+[[:space:]]*$/ { priority=$2; next }
        END {
            choose()
            if (selected != "") print selected
            else exit 1
        }
    ' <<<"$info"
}


desktop_get_display_description() {
    local connector
    connector=$(desktop_get_connector_name) || return 1
    printf '%s\n' "$connector"
}

desktop_resolve_active_connector() {
    local connector
    connector=$(desktop_get_connector_name) || {
        fail "unable to resolve an active Desktop Mode display output"
        return 1
    }
    ACTIVE_CONNECTOR=$connector
    log "Desktop display output verified: $connector"
    printf '%s\n' "$connector"
}

_desktop_normalize_mode() {
    local mode=$1 width height refresh
    mode=$(sed -E 's/^[0-9]+://; s/[^0-9x@.]+$//' <<<"$mode")
    [[ "$mode" =~ ^[0-9]+x[0-9]+@[0-9.]+$ ]] || return 1
    width=${mode%%x*}
    height=${mode#*x}
    height=${height%%@*}
    refresh=${mode#*@}
    refresh=$(awk -v r="$refresh" 'BEGIN { printf "%d", r + 0.5 }')
    printf '%sx%s@%s\n' "$width" "$height" "$refresh"
}

desktop_get_host_mode_list() {
    local connector block modes
    connector=$(host_connector) || return 1
    block=$(_desktop_output_block "$connector") || return 1
    modes=$(tr '\n' ' ' <<<"$block" |
        grep -oE '[0-9]+:[0-9]+x[0-9]+@[0-9.]+' |
        while IFS= read -r token; do
            _desktop_normalize_mode "$token" || true
        done | sort -u)
    [[ -n "$modes" ]] || return 1
    printf '%s\n' "$modes"
}

desktop_mode_list_contains() {
    # Exact line match without a `| grep -Fxq` pipeline (pipefail/SIGPIPE).
    local wanted=$1 list
    list=$(desktop_get_host_mode_list) || return 1
    [[ $'\n'"$list"$'\n' == *$'\n'"$wanted"$'\n'* ]]
}

desktop_get_current_mode() {
    local connector block token
    connector=$(host_connector) || return 1
    block=$(_desktop_output_block "$connector") || return 1
    token=$(tr '\n' ' ' <<<"$block" |
        grep -oE '[0-9]+:[0-9]+x[0-9]+@[0-9.]+[^[:space:]]*' |
        grep '\*' | head -n1) || return 1
    _desktop_normalize_mode "$token"
}

desktop_is_target_mode_active() {
    local current res want_w want_h cur_w cur_h
    res="${TARGET_WIDTH:-$STREAM_WIDTH}x${TARGET_HEIGHT:-$STREAM_HEIGHT}"
    current=$(desktop_get_current_mode 2>/dev/null || true)
    [[ -n "$current" ]] || return 1
    [[ "$current" == "${res}@${TARGET_REFRESH:-$STREAM_REFRESH}" ]] && return 0

    want_w=${res%%x*}
    want_h=${res#*x}
    cur_w=${current%%x*}
    cur_h=${current#*x}
    cur_h=${cur_h%%@*}
    [[ "$cur_w" == "$want_w" && "$cur_h" == "$want_h" ]]
}

desktop_apply_target() {
    local connector mode
    connector=$(host_connector) || return 1
    mode="${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
    desktop_mode_list_contains "$mode" || {
        fail "Desktop output '$connector' does not advertise $mode"
        return 1
    }
    log "Applying Desktop target mode: $connector -> $mode"
    kscreen-doctor "output.$connector.mode.$mode" >/dev/null
}

desktop_wait_for_target_mode() {
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if desktop_is_target_mode_active; then return 0; fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

desktop_wait_for_original_mode() {
    local want=${1:-${HOST_ORIGINAL_MODE:-}}
    [[ -n "$want" ]] || return 1
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        local current
        current=$(desktop_get_current_mode 2>/dev/null || true)
        [[ "$current" == "$want" ]] && return 0
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

desktop_restore_host_mode() {
    local connector mode
    mode=$(original_mode_for_restore) || true
    [[ -n "$mode" ]] || {
        log "WARNING: no original Desktop display mode recorded; skipping mode restore"
        return 0
    }
    connector=$(host_connector) || return 1
    desktop_mode_list_contains "$mode" || {
        fail "original Desktop mode '$mode' is no longer advertised by '$connector'"
        return 1
    }
    log "Restoring Desktop host mode: $connector -> $mode"
    kscreen-doctor "output.$connector.mode.$mode" >/dev/null
}


desktop_monitor_connector() {
    local connector
    connector="${HOST_CONNECTOR:-}"
    if [[ -z "$connector" ]]; then
        connector=$(state_field ORIGINAL_CONNECTOR 2>/dev/null || true)
    fi
    if [[ -z "$connector" ]]; then
        connector="${ACTIVE_CONNECTOR:-}"
    fi
    [[ -n "$connector" ]] || return 1
    printf '%s\n' "$connector"
}

desktop_dpms_report() {
    # "dpms mode for screen DP-3: on" -> current DPMS state for one connector.
    local connector=$1
    TERM=dumb NO_COLOR=1 kscreen-doctor --dpms show 2>/dev/null |
        sed -E 's/\x1B\[[0-9;]*m//g' |
        grep -F "screen ${connector}:" | tail -n1 | sed -E 's/.*: *//'
}

desktop_set_monitor_power() {
    # Turn the physical panel off/on through DPMS. The output stays attached to
    # the compositor, so Steam Link keeps a surface to capture; this is the
    # Desktop equivalent of the Gamescope external-screen sleep. Removing the
    # output instead (output.<conn>.disable) would detach it from the
    # compositor and break the capture.
    local want=$1 connector current deadline
    connector=$(desktop_monitor_connector) || {
        fail "unable to resolve the Desktop output for monitor power"
        return 1
    }
    log "Setting Desktop DPMS '$want' (output $connector)"
    if ! kscreen-doctor --dpms "$want" >/dev/null; then
        fail "kscreen-doctor --dpms $want failed for $connector"
        return 1
    fi
    deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        current=$(desktop_dpms_report "$connector" 2>/dev/null || true)
        [[ "$current" == "$want" ]] && return 0
        sleep "$POLL_INTERVAL_SECONDS"
    done
    fail "Desktop DPMS did not reach '$want' for $connector (current=${current:-unknown})"
    return 1
}

desktop_screen_sleep() {
    if [[ "${MONITOR_POWER_MODE:-off}" == off && "${VIRTUAL_DISPLAY_ACTIVE:-0}" == 1 ]]; then
        local connector
        connector="${HOST_CONNECTOR:-}"
        [[ -n "$connector" ]] || connector=$(state_field ORIGINAL_CONNECTOR 2>/dev/null || true)
        [[ -n "$connector" ]] || {
            fail "unable to resolve the physical Desktop output to disable"
            return 1
        }

        log "Disabling physical Desktop output for virtual stream display: $connector"
        kscreen-doctor "output.$connector.disable" >/dev/null || {
            fail "failed to disable physical Desktop output '$connector'"
            return 1
        }
        log_event DESKTOP_PHYSICAL_OUTPUT_DISABLED "$connector"
        return 0
    fi

    desktop_set_monitor_power off
}

desktop_screen_wake() {
    if [[ "${VIRTUAL_DISPLAY_ACTIVE:-0}" == 1 ]]; then
        local connector
        connector="${HOST_CONNECTOR:-}"
        [[ -n "$connector" ]] || connector=$(state_field ORIGINAL_CONNECTOR 2>/dev/null || true)
        [[ -n "$connector" ]] || {
            fail "unable to resolve the physical Desktop output to enable"
            return 1
        }

        log "Re-enabling physical Desktop output after virtual stream display: $connector"
        kscreen-doctor "output.$connector.enable" >/dev/null || {
            fail "failed to enable physical Desktop output '$connector'"
            return 1
        }
        return 0
    fi

    desktop_set_monitor_power on
}

desktop_apply_target_mode() {
    desktop_apply_target
    desktop_wait_for_target_mode
}

desktop_prepare_stream_mode() {
    log_event OUTPUT_PREPARE_START
    state_write 'PREPARING'

    local current
    if [[ "${MONITOR_POWER_MODE:-off}" == off ]]; then
        # Monitor-off Desktop sessions use a dedicated KWin virtual output.
        # The physical output is left enabled until the common monitor-power
        # phase has a verified virtual canvas to move the game onto.
        desktop_virtual_display_prepare || return 1
        # The virtual output is created at the resolved target, so that is the
        # geometry to report (the physical output is irrelevant here).
        current="${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}"
    else
        if ! desktop_apply_target_mode; then
            fail "Desktop target mode could not be applied or verified"
            return 1
        fi
        current=$(desktop_get_current_mode 2>/dev/null || printf '%sx%s@%s' "$TARGET_WIDTH" "$TARGET_HEIGHT" "$TARGET_REFRESH")
    fi
    log "Verified Desktop target mode: $current (source=$TARGET_SOURCE)"
    log_event OUTPUT_TARGET_REACHED "$current"

    state_write 'PREPARED'
    state_write 'STREAMING'
    SETUP_DONE=1
}

desktop_restore_host_state() {
    # Full layout restore: mode, position, scale, primary and enabled state for
    # every output that still exists, applied in one atomic kscreen-doctor call
    # so the compositor cannot re-place the other outputs half-way. The virtual
    # output (when present) is removed after the physical layout is back.
    local layout original_mode
    layout="${HOST_ORIGINAL_LAYOUT:-}"
    [[ -n "$layout" ]] || layout=$(state_field ORIGINAL_DESKTOP_LAYOUT 2>/dev/null || true)

    if [[ -n "$layout" ]]; then
        desktop_layout_restore "$layout" || return 1
    else
        # State written by an older build: mode-only restore.
        desktop_restore_host_mode || return 1
    fi

    if [[ "${VIRTUAL_DISPLAY_ACTIVE:-0}" == 1 ]]; then
        desktop_virtual_display_destroy || return 1
    fi

    original_mode=$(original_mode_for_restore)
    if [[ -n "$original_mode" ]]; then
        if desktop_wait_for_original_mode "$original_mode"; then
            log "Verified original Desktop mode: $original_mode"
        else
            log "WARNING: original Desktop mode verification timed out"
        fi
    fi
    return 0
}

desktop_recover_stale_state() {
    local stale_unit stale_layout
    stale_unit=$(state_field VIRTUAL_DISPLAY_UNIT 2>/dev/null || true)
    stale_layout=$(state_field ORIGINAL_DESKTOP_LAYOUT 2>/dev/null || true)

    # Tear the virtual output down first, then put the whole physical layout
    # back (mode, position, scale, primary) from the saved snapshot.
    if [[ "${VIRTUAL_DISPLAY_ACTIVE:-0}" == 1 || -n "$stale_unit" ]]; then
        desktop_virtual_display_recover_stale_state || return 1
    fi
    if [[ -n "$stale_layout" ]]; then
        desktop_layout_restore "$stale_layout" || return 1
    fi

    local verify_mode
    verify_mode=$(original_mode_for_restore)
    log "Saved Desktop run profile: connector=$(state_field ORIGINAL_CONNECTOR 2>/dev/null || true) mode=${verify_mode:-unavailable}"
    if [[ -n "$verify_mode" ]]; then
        desktop_restore_host_mode || return 1
        desktop_wait_for_original_mode "$verify_mode" || {
            log "ERROR: stale-state recovery could not verify the original Desktop mode"
            return 1
        }
        log "Verified original Desktop mode: $verify_mode"
        HOST_ORIGINAL_MODE=$verify_mode
    else
        log "WARNING: stale Desktop state has no original mode"
    fi
    HOST_ORIGINAL_XWAYLAND_MODE=''
}

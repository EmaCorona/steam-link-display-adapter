#!/usr/bin/env bash
# shellcheck shell=bash
# KDE/KWin virtual stream display for Desktop Mode Steam Link sessions.
#
# `krfb-virtualmonitor` creates a compositor-level virtual output, but it is
# also a VNC server (libvncserver): it necessarily listens on a TCP port and the
# installed version cannot disable that. A bare invocation would therefore
# expose the user's desktop on the network for the whole stream.
#
# Constraints enforced here:
#   * the process runs inside a user systemd unit with PrivateNetwork=yes, so it
#     has no connectivity to the host network at all (only its own loopback);
#   * a random per-run VNC password is generated, passed to the process and
#     never logged or persisted (the unit name is what identifies the session);
#   * when the isolation cannot be established the whole Desktop stream fails
#     closed: no fallback to DPMS or to a bare output disable;
#   * the lifecycle is unit-based (systemctl --user stop), never a bare kill of
#     a PID read from a state file.

set -Eeuo pipefail

DESKTOP_VIRTUAL_DISPLAY_NAME=${DESKTOP_VIRTUAL_DISPLAY_NAME:-SteamLinkDisplayAdapter}

desktop_virtual_display_command_available() {
    command -v krfb-virtualmonitor >/dev/null 2>&1
}

desktop_virtual_unit_name() {
    # Deterministic, session-scoped unit name (also stored in the run state so
    # recovery can stop exactly this unit and nothing else).
    local name=${1:-$DESKTOP_VIRTUAL_DISPLAY_NAME}
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '-')
    printf 'steam-link-virtual-%s.service\n' "$name"
}

desktop_virtual_isolation_available() {
    # A user systemd unit with PrivateNetwork=yes is the isolation: the payload
    # sees only its own loopback and has no route to the host network. Verified
    # on the real system before trusting it.
    command -v systemd-run >/dev/null 2>&1 || return 1
    command -v systemctl >/dev/null 2>&1 || return 1

    local state
    state=$(systemctl --user is-system-running 2>/dev/null || true)
    [[ "$state" != offline && "$state" != unknown && -n "$state" ]] || return 1

    local ifaces
    ifaces=$(systemd-run --user --quiet --collect --wait --pipe \
        -p PrivateNetwork=yes /bin/sh -c 'ls -1 /sys/class/net' 2>/dev/null || true)
    [[ "$ifaces" == lo ]]
}

desktop_virtual_generate_password() {
    # Random per-run password. Never logged, never persisted.
    local pw
    pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24) || true
    [[ ${#pw} -ge 16 ]] || return 1
    printf '%s\n' "$pw"
}

desktop_virtual_free_port() {
    # Pick a port that is closed on the host, so the reachability proof after
    # the start is unambiguous (nothing else can answer on it).
    local port
    for port in $(seq 59100 59199); do
        if ! timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    return 1
}

_desktop_virtual_output_list() {
    desktop_kscreen_outputs
}

desktop_virtual_display_output() {
    # KWin exposes the virtual output as "Virtual-<name>".
    local expected="Virtual-$DESKTOP_VIRTUAL_DISPLAY_NAME"
    _desktop_virtual_output_list |
        awk -v want="$expected" '
            /^Output:/ && $3 == want { print $3; found=1; exit }
            END { if (!found) exit 1 }
        '
}

desktop_virtual_display_exists() {
    desktop_virtual_display_output >/dev/null 2>&1
}

_desktop_virtual_port_open_on_host() {
    local port=$1
    timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null
}

desktop_virtual_display_create() {
    local resolution="$TARGET_WIDTH"x"$TARGET_HEIGHT"
    local name="$DESKTOP_VIRTUAL_DISPLAY_NAME"
    local unit port password output deadline

    desktop_virtual_display_command_available || {
        fail "Desktop monitor-off mode requires krfb-virtualmonitor"
        return 1
    }

    # Fail closed: without a proven network isolation the VNC listener would be
    # exposed on the host network, so the mode is refused (never a DPMS or
    # output-disable fallback).
    if ! desktop_virtual_isolation_available; then
        fail "Desktop monitor-off mode requires an isolated network namespace (systemd-run --user -p PrivateNetwork=yes)"
        return 1
    fi

    if desktop_virtual_display_exists; then
        fail "virtual stream display '$name' already exists"
        return 1
    fi

    unit=$(desktop_virtual_unit_name "$name")
    if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
        fail "virtual stream display unit '$unit' is already active"
        return 1
    fi

    port=$(desktop_virtual_free_port) || {
        fail "no free local port available for the virtual stream display"
        return 1
    }
    password=$(desktop_virtual_generate_password) || {
        fail "could not generate the virtual stream display password"
        return 1
    }

    output="Virtual-$name"
    log "Creating Desktop virtual stream display: $resolution ($name, unit $unit)"

    # The password is passed on the command line and never logged; the unit name
    # is the session identifier for recovery.
    if ! systemd-run --user --quiet --collect --unit="$unit" \
        -p PrivateNetwork=yes -- \
        krfb-virtualmonitor --resolution "$resolution" --name "$name" \
        --password "$password" --port "$port" >/dev/null 2>&1; then
        fail "could not start the isolated virtual stream display unit '$unit'"
        return 1
    fi
    unset password

    VIRTUAL_DISPLAY_ACTIVE=1
    VIRTUAL_DISPLAY_UNIT=$unit
    VIRTUAL_DISPLAY_NAME=$name
    VIRTUAL_DISPLAY_OUTPUT=$output
    VIRTUAL_DISPLAY_PORT=$port

    # Persist ownership immediately so recovery can identify the unit/output
    # even if the interruption happens before the output appears.
    state_write 'PREPARING'

    deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if desktop_virtual_display_exists; then
            log "Desktop virtual stream display appeared: $output"
            log_event VIRTUAL_DISPLAY_CREATED "$output/$resolution"
            break
        fi
        if ! systemctl --user is-active --quiet "$unit" 2>/dev/null; then
            fail "virtual stream display unit exited before the output appeared"
            VIRTUAL_DISPLAY_ACTIVE=0
            return 1
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done

    if ! desktop_virtual_display_exists; then
        fail "virtual stream display did not appear within ${MODE_TIMEOUT_SECONDS}s"
        return 1
    fi

    # Security proof (spec §6): the listener must NOT be reachable from the host
    # network namespace. The port was free before the start, so a successful
    # connection here would prove the isolation failed.
    if _desktop_virtual_port_open_on_host "$port"; then
        fail "virtual stream display port $port is reachable from the host network: network isolation failed"
        return 1
    fi
    log "Virtual stream display listener is not reachable from the host network (port $port)"
    log_event VIRTUAL_DISPLAY_ISOLATED "$output/$port"
    return 0
}

desktop_virtual_display_set_primary() {
    local output
    output=$(desktop_virtual_display_output) || {
        fail "virtual stream display is not visible in KScreen"
        return 1
    }

    log "Setting Desktop virtual stream display as primary: $output"
    desktop_kscreen_apply "output.$output.primary" || {
        fail "failed to set '$output' as the primary Desktop output"
        return 1
    }
    # Postcondition: the virtual output must be observably primary.
    desktop_kscreen_verify_field "$output" primary 1 || return 1
}

desktop_virtual_display_destroy() {
    local unit="$VIRTUAL_DISPLAY_UNIT"
    local output="$VIRTUAL_DISPLAY_OUTPUT"
    local deadline

    [[ -n "$unit" ]] || unit=$(state_field VIRTUAL_DISPLAY_UNIT 2>/dev/null || true)
    if [[ -z "$output" ]]; then
        if [[ -n "${VIRTUAL_DISPLAY_NAME:-}" ]]; then
            output="Virtual-$VIRTUAL_DISPLAY_NAME"
        else
            output="Virtual-$DESKTOP_VIRTUAL_DISPLAY_NAME"
        fi
    fi

    if [[ -n "$unit" ]]; then
        # Unit-based stop: identity is the unit name we created, so a recycled
        # PID can never be signalled by mistake.
        log "Stopping Desktop virtual stream display unit: $unit"
        systemctl --user stop "$unit" >/dev/null 2>&1 || true
        deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
        while (( SECONDS <= deadline )); do
            systemctl --user is-active --quiet "$unit" 2>/dev/null || break
            sleep "$POLL_INTERVAL_SECONDS"
        done
        if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
            log "WARNING: virtual stream display unit '$unit' is still active"
            return 1
        fi
    fi

    deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        desktop_virtual_display_exists || break
        sleep "$POLL_INTERVAL_SECONDS"
    done

    if desktop_virtual_display_exists; then
        log "WARNING: virtual stream display '$output' is still visible after unit stop"
        return 1
    fi

    VIRTUAL_DISPLAY_UNIT=
    VIRTUAL_DISPLAY_NAME=
    VIRTUAL_DISPLAY_OUTPUT=
    VIRTUAL_DISPLAY_PORT=
    VIRTUAL_DISPLAY_ACTIVE=0
    log_event VIRTUAL_DISPLAY_DESTROYED "$output"
    return 0
}

desktop_virtual_display_prepare() {
    desktop_virtual_display_create || return 1
    desktop_virtual_display_set_primary || {
        desktop_virtual_display_destroy || true
        return 1
    }
}


desktop_virtual_display_recover_stale_state() {
    VIRTUAL_DISPLAY_UNIT=$(state_field VIRTUAL_DISPLAY_UNIT 2>/dev/null || true)
    VIRTUAL_DISPLAY_NAME=$(state_field VIRTUAL_DISPLAY_NAME 2>/dev/null || true)
    VIRTUAL_DISPLAY_OUTPUT=$(state_field VIRTUAL_DISPLAY_OUTPUT 2>/dev/null || true)
    VIRTUAL_DISPLAY_ACTIVE=1

    if [[ -n "$VIRTUAL_DISPLAY_UNIT" ]] || desktop_virtual_display_exists; then
        desktop_virtual_display_destroy || return 1
    fi

    VIRTUAL_DISPLAY_UNIT=
    VIRTUAL_DISPLAY_NAME=
    VIRTUAL_DISPLAY_OUTPUT=
    VIRTUAL_DISPLAY_ACTIVE=0
    return 0
}

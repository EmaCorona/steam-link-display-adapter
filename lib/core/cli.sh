#!/usr/bin/env bash
# shellcheck shell=bash
# Wrapper command line (Steam Launch Options).
#
# steam-link-display-adapter %command%
#
# The wrapper consumes only its own options BEFORE the game command and
# forwards the game command (and anything after it) verbatim. The public
# options control adapter behaviour; the game command itself is passed through
# unchanged.
#
# A missing game command, an invalid option value, an unsupported option
# (including the removed --mode forms) or an unknown option aborts before any
# display or state change (fail-closed).

GAME_ARGS=()
MONITOR_POWER_MODE='off'

usage() {
    cat >&2 <<'EOF'
Usage:
  steam-link-display-adapter [--monitor on|off] %command%

Options:
  --monitor on|off   Keep the monitor on, or turn it off during an active
                     Steam Link stream. Default: off.
  --help             Show this help.

The wrapper forwards the game command unchanged. The streaming target is
resolved automatically from the Steam Link client and the host capabilities.
EOF
}

parse_wrapper_args() {
    while (( $# > 0 )); do
        case "$1" in
            --help)
                usage; exit 0 ;;
            --monitor)
                shift
                if (( $# == 0 )); then
                    fail "--monitor requires 'on' or 'off'"
                    exit 64
                fi
                case "$1" in
                    on|off) MONITOR_POWER_MODE=$1 ;;
                    *) fail "--monitor value must be 'on' or 'off'"; exit 64 ;;
                esac
                shift
                ;;
            --monitor=*)
                value=${1#*=}
                case "$value" in
                    on|off) MONITOR_POWER_MODE=$value ;;
                    *) fail "--monitor value must be 'on' or 'off'"; exit 64 ;;
                esac
                shift
                ;;
            --)
                shift; break ;;
            --mode|--mode=*)
                fail "--mode is no longer supported; use 'steam-link-display-adapter %command%'"
                exit 64 ;;
            -*)
                fail "unknown wrapper option: $1"
                exit 64 ;;
            *)
                break ;;
        esac
    done
    GAME_ARGS=("$@")
    [[ ${#GAME_ARGS[@]} -gt 0 ]] || { usage; exit 64; }
}

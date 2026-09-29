#!/usr/bin/env bash
# shellcheck shell=bash
# Wrapper command line (Steam Launch Options).
#
# steam-link-display-adapter [OPTIONS] %command%
#
# Only the wrapper options BEFORE the game command are consumed; the game
# command (and anything after it) is forwarded verbatim. Supported:
#   --mode auto | WxH            (per-game target override)
#   --help
# A missing/duplicate/unknown option or an invalid --mode value aborts before
# any display or state change.
#
# Public command line, arguments, flags and exit codes are unchanged.

MODE_SOURCE=''
MODE_SPEC=''
CLI_WIDTH=''
CLI_HEIGHT=''
GAME_ARGS=()

usage() {
    cat >&2 <<'EOF'
Usage:
  steam-link-display-adapter [OPTIONS] %command%

Options:
  --mode auto        Use dynamic resolution based on the Steam Link client.
  --mode WxH         Force the resolution and choose a compatible refresh automatically.
  --help             Show this help.

Examples:
  steam-link-display-adapter --mode auto %command%
  steam-link-display-adapter --mode 1920x1200 %command%
EOF
}

parse_mode_value() {
    # Validate a --mode value and fill the CLI request fields.
    local v=$1
    if [[ "$v" == auto ]]; then
        MODE_SOURCE=auto; MODE_SPEC=auto
        CLI_WIDTH=''; CLI_HEIGHT=''
        return 0
    fi
    # Only "WxH": the refresh is never set from the CLI (it is a resolver
    # concern), so any "@FPS" form is invalid (spec 2026-09-29).
    if [[ "$v" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]]; then
        MODE_SOURCE=cli; MODE_SPEC=$v
        CLI_WIDTH=${BASH_REMATCH[1]}; CLI_HEIGHT=${BASH_REMATCH[2]}
        return 0
    fi
    return 1
}

parse_wrapper_args() {
    local mode_seen=0
    while (( $# > 0 )); do
        case "$1" in
            --help)
                usage; exit 0 ;;
            --mode)
                (( mode_seen )) && { fail "duplicate --mode option"; exit 64; }
                [[ $# -ge 2 ]] || { fail "--mode requires a value"; exit 64; }
                parse_mode_value "$2" || { fail "invalid --mode value: $2"; exit 64; }
                mode_seen=1
                shift 2 ;;
            --mode=*)
                (( mode_seen )) && { fail "duplicate --mode option"; exit 64; }
                parse_mode_value "${1#--mode=}" || { fail "invalid --mode value: ${1#--mode=}"; exit 64; }
                mode_seen=1
                shift ;;
            --)
                shift; break ;;
            -*)
                fail "unknown wrapper option: $1"; exit 64 ;;
            *)
                break ;;
        esac
    done
    GAME_ARGS=("$@")
    [[ ${#GAME_ARGS[@]} -gt 0 ]] || { usage; exit 64; }
}

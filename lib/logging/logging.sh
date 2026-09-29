#!/usr/bin/env bash
# shellcheck shell=bash
# Logging and wrapper event tracing.
#
# Timestamped lines go to LOG_FILE when it is set (the wrapper), otherwise to
# stdout (helpers sourced without a log file, e.g. the restore command). The
# monotonic wrapper events (T<ms>ms EVENT [detail]) are emitted through
# log_event(); _sl_event() is the tolerant variant used by the detection layer,
# which is also sourced by the restore command.

set -Eeuo pipefail

log_file() {
    # The wrapper always has LOG_FILE; helpers sourced without a log file (the
    # restore command) keep the historical stdout behaviour.
    local line
    line=$(printf '[%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >>"$LOG_FILE"
    else
        printf '%s\n' "$line"
    fi
}

log() {
    log_file "$*"
}

now_ms() {
    printf '%s\n' $(( ($(date +%s%N) - WRAPPER_START_NS) / 1000000 ))
}

log_event() {
    log "T$(now_ms)ms $1${2:+ $2}"
}

fail() {
    log "ERROR: $*"
    printf 'steam-link-display-adapter: ERROR: %s\n' "$*" >&2
    return 1
}

_sl_event() {
    # Emit a monotonic wrapper event when the wrapper's log_event exists (the
    # hook is also sourced by the standalone restore helper, which has no file
    # log); fall back to the plain log otherwise.
    if declare -F log_event >/dev/null 2>&1; then
        log_event "$1" "${2:-}"
    else
        log "$1${2:+ $2}"
    fi
}

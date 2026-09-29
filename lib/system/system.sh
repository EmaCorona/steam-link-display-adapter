#!/usr/bin/env bash
# shellcheck shell=bash
# Shared system primitives.

set -Eeuo pipefail

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "ERROR: required command not found: $1"
        return 1
    }
}

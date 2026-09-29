#!/usr/bin/env bash
# shellcheck shell=bash
# Single-instance lock (flock on the state directory).

set -Eeuo pipefail

lock_acquire() {
    exec 9>"$LOCK_FILE"
    flock -n 9
}

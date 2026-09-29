#!/usr/bin/env bash
# shellcheck shell=bash
# Library loader.
#
# The entrypoints resolve LIB_ROOT once (repository checkout: <root>/lib;
# installed: ~/.local/lib/steam-link-display-adapter/) and then load modules by
# name relative to that root, so no module ever needs a fragile relative path.
#
# Dependency direction: bin -> core -> domain modules -> system primitives.

: "${LIB_ROOT:?LIB_ROOT must be set by the entrypoint before bootstrap.sh}"

sl_load() {
    # Load one module by its path relative to LIB_ROOT.
    local rel=$1
    # shellcheck disable=SC1090
    source "$LIB_ROOT/$rel"
}

# Domain modules: definitions only, no side effects. Loaded low level first.
sl_load logging/logging.sh
sl_load system/system.sh
sl_load detection/gamescope.sh
sl_load detection/steam-link.sh
sl_load display/connector.sh
sl_load display/mode.sh
sl_load resolution/resolver.sh
sl_load xwayland/mode.sh
sl_load state/state.sh
sl_load state/snapshot.sh
sl_load state/lock.sh

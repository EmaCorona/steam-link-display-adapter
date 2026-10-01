#!/usr/bin/env bash
# shellcheck shell=bash
# Full KDE/KScreen layout snapshot and idempotent restore.
#
# Disabling or enabling one output can make the compositor re-place the other
# outputs, so the whole layout is captured before a Desktop session and put back
# afterwards. The snapshot is a single state-friendly line; the restore is one
# atomic kscreen-doctor invocation (the tool applies all settings in one go).

set -Eeuo pipefail

desktop_output_names() {
    desktop_kscreen_outputs | awk '/^Output:/ { print $3 }'
}

desktop_output_exists() {
    local want=$1
    [[ -n "$want" ]] || return 1
    desktop_output_names | grep -Fxq -- "$want"
}

desktop_rotation_name() {
    # KScreen reports rotation numerically; kscreen-doctor sets it by name.
    case "${1:-}" in
        1) printf 'none\n' ;;
        2) printf 'left\n' ;;
        4) printf 'inverted\n' ;;
        8) printf 'right\n' ;;
        *) return 1 ;;
    esac
}

desktop_layout_snapshot() {
    # One line: connector|enabled|primary|priority|mode|position|scale|rotation
    # separated by ';' -- one record per output, in the order KScreen lists them.
    local info
    info=$(desktop_kscreen_outputs) || return 1
    awk '
        function flush() {
            if (conn == "") return
            if (n++) printf ";"
            printf "%s|%s|%s|%s|%s|%s|%s|%s", conn, enabled, primary, prio, mode, pos, scale, rot
        }
        /^Output:/ {
            flush()
            conn=$3; enabled=1; primary=0; prio=""; mode=""; pos=""; scale=""; rot=""
            if ($0 ~ /(^|[[:space:]])primary([[:space:]]|$)/) primary=1
            if ($0 ~ /(^|[[:space:]])disabled([[:space:]]|$)/) enabled=0
            next
        }
        /^[[:space:]]+disabled[[:space:]]*$/ { enabled=0; next }
        /^[[:space:]]+enabled[[:space:]]*$/ { enabled=1; next }
        /^[[:space:]]+priority[[:space:]]+[0-9]+/ { prio=$2; next }
        /^[[:space:]]+Geometry:[[:space:]]*/ {
            g=$0
            sub(/^[[:space:]]*Geometry:[[:space:]]*/, "", g)
            split(g, a, /[[:space:]]+/)
            pos=a[1]
            next
        }
        /^[[:space:]]+Scale:[[:space:]]*/ { scale=$2; next }
        /^[[:space:]]+Rotation:[[:space:]]*/ { rot=$2; next }
        /Modes:/ {
            ntok=split($0, toks, /[[:space:]]+/)
            for (i=1; i<=ntok; i++) {
                if (toks[i] ~ /\*/) {
                    m=toks[i]
                    sub(/^[0-9]+:/, "", m)
                    sub(/\*.*$/, "", m)
                    mode=m
                }
            }
            next
        }
        END { flush() }
    ' <<<"$info"
}

desktop_layout_restore() {
    # Re-apply the snapshot with a single kscreen-doctor call. Outputs that no
    # longer exist are skipped (a monitor may have been unplugged); the fields
    # this tool cannot set (priority) are reported but not enforced.
    local snapshot=${1:-}
    [[ -n "$snapshot" ]] || {
        log "WARNING: no Desktop layout snapshot recorded; skipping layout restore"
        return 0
    }

    local existing primary_target=''
    existing=$(desktop_output_names 2>/dev/null || true)

    local args=() record conn enabled primary prio mode pos scale rot rotation
    local old_ifs=$IFS
    for record in ${snapshot//;/ }; do
        IFS='|' read -r conn enabled primary prio mode pos scale rot <<<"$record"
        [[ -n "$conn" ]] || continue
        if ! grep -Fxq -- "$conn" <<<"$existing"; then
            continue
        fi

        if [[ "$enabled" == 1 ]]; then
            args+=("output.$conn.enable")
        else
            args+=("output.$conn.disable")
        fi
        [[ -n "$mode" ]] && args+=("output.$conn.mode.$mode")
        [[ -n "$pos" ]] && args+=("output.$conn.position.$pos")
        [[ -n "$scale" ]] && args+=("output.$conn.scale.$scale")
        if rotation=$(desktop_rotation_name "$rot"); then
            args+=("output.$conn.rotation.$rotation")
        fi
        [[ "$primary" == 1 ]] && primary_target=$conn
    done
    IFS=$old_ifs

    [[ -n "$primary_target" ]] && args+=("output.$primary_target.primary")

    ((${#args[@]})) || return 0
    log "Restoring Desktop layout (${#args[@]} settings)"
    log_event DESKTOP_LAYOUT_RESTORE "${#args[@]}"
    kscreen-doctor "${args[@]}" >/dev/null
}

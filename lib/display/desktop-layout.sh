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
            # Real KScreen marks the primary output with priority 1 and prints no
            # literal 'primary' token (measured 2026-10-01 on KDE: the virtual
            # output became priority 1 while DP-3 moved to 2). The token is kept
            # as an additional signal for renderings that do emit it.
            p = primary
            if (prio == 1) p = 1
            printf "%s|%s|%s|%s|%s|%s|%s|%s", conn, enabled, p, prio, mode, pos, scale, rot
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
        if [[ -n "$mode" ]]; then
            local mode_token
            mode_token=$(_desktop_normalize_mode "$mode") || mode_token=$mode
            args+=("output.$conn.mode.$mode_token")
        fi
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
    desktop_kscreen_apply "${args[@]}" || return 1
}

desktop_layout_normalize_for_verify() {
    # Canonical form used only for comparison:
    # connector|enabled|primary|mode|position|scale|rotation
    # Priority is excluded because it is reported but not restorable through
    # the kscreen-doctor contract used by the adapter.
    local snapshot=${1:-} record conn enabled primary prio mode pos scale rot mode_token
    [[ -n "$snapshot" ]] || return 0

    for record in ${snapshot//;/ }; do
        IFS='|' read -r conn enabled primary prio mode pos scale rot <<<"$record"
        [[ -n "$conn" ]] || continue
        mode_token=
        if [[ -n "$mode" ]]; then
            mode_token=$(_desktop_normalize_mode "$mode" 2>/dev/null || printf '%s' "$mode")
        fi
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$conn" "$enabled" "$primary" "$mode_token" "$pos" "$scale" "$rot"
    done | sort -t'|' -k1,1
}

desktop_layout_verify() {
    # Verify the final physical Desktop layout after all restore operations.
    # Extra outputs (not present in the saved snapshot, such as the temporary KWin
    # virtual output) are ignored. Every saved output must match the fields that
    # the restore contract can control. A missing saved output is an incomplete
    # restore because the original layout cannot be reproduced.
    local expected=${1:-} actual expected_norm actual_norm
    [[ -n "$expected" ]] || return 0

    actual=$(desktop_layout_snapshot 2>/dev/null || true)
    [[ -n "$actual" ]] || {
        fail "Desktop layout verification could not read the current KScreen layout"
        return 1
    }

    expected_norm=$(desktop_layout_normalize_for_verify "$expected")
    actual_norm=$(desktop_layout_normalize_for_verify "$actual")

    local failures=0
    local record conn e_enabled e_primary e_mode e_pos e_scale e_rot
    local a_enabled a_primary a_mode a_pos a_scale a_rot actual_record

    while IFS='|' read -r conn e_enabled e_primary e_mode e_pos e_scale e_rot; do
        [[ -n "$conn" ]] || continue
        actual_record=$(awk -F'|' -v want="$conn" '$1 == want { print; exit }' <<<"$actual_norm")
        if [[ -z "$actual_record" ]]; then
            fail "Desktop layout verification: expected output '$conn' is missing"
            failures=$((failures + 1))
            continue
        fi

        IFS='|' read -r _ a_enabled a_primary a_mode a_pos a_scale a_rot <<<"$actual_record"

        if [[ "$a_enabled" != "$e_enabled" ]]; then
            fail "Desktop layout verification: output '$conn' enabled=$a_enabled, expected=$e_enabled"
            failures=$((failures + 1))
        fi
        if [[ "$a_primary" != "$e_primary" ]]; then
            fail "Desktop layout verification: output '$conn' primary=$a_primary, expected=$e_primary"
            failures=$((failures + 1))
        fi
        if [[ "$a_mode" != "$e_mode" ]]; then
            fail "Desktop layout verification: output '$conn' mode=$a_mode, expected=$e_mode"
            failures=$((failures + 1))
        fi
        if [[ "$a_pos" != "$e_pos" ]]; then
            fail "Desktop layout verification: output '$conn' position=$a_pos, expected=$e_pos"
            failures=$((failures + 1))
        fi
        if [[ "$a_scale" != "$e_scale" ]]; then
            fail "Desktop layout verification: output '$conn' scale=$a_scale, expected=$e_scale"
            failures=$((failures + 1))
        fi
        if [[ "$a_rot" != "$e_rot" ]]; then
            fail "Desktop layout verification: output '$conn' rotation=$a_rot, expected=$e_rot"
            failures=$((failures + 1))
        fi
    done <<<"$expected_norm"

    if (( failures > 0 )); then
        log_event DESKTOP_LAYOUT_VERIFY_FAILED "$failures"
        return 1
    fi

    log "Verified Desktop layout after restore"
    log_event DESKTOP_LAYOUT_VERIFIED
    return 0
}
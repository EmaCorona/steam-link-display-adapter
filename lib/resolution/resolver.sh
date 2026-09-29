#!/usr/bin/env bash
# shellcheck shell=bash
# --- Dynamic client resolution (spec: risoluzione Gamescope dinamica) --------
#
# The stream geometry is no longer a constant: Steam writes the client capture
# ceiling in its host log ("Maximum capture: WxH FPS") a few ms before creating
# the streaming sink, and the wrapper turns that hint into a runtime target
# (TARGET_WIDTH/HEIGHT/REFRESH), resolved against the modes the host really
# advertises. The configured STREAM_* values remain the fallback.
#
# This module decides WHICH mode to use; applying it is display/.

set -Eeuo pipefail

sl_aspect_milli() {
    # Aspect ratio in thousandths (integer math): 1280x800 -> 1600.
    local w=$1 h=$2
    [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || return 1
    (( w > 0 && h > 0 )) || return 1
    printf '%s\n' $(( w * 1000 / h ))
}

sl_aspect_compatible() {
    # True when two resolutions have a compatible aspect ratio within
    # STREAM_ASPECT_TOLERANCE percent (default 5).
    local aw=$1 ah=$2 bw=$3 bh=$4 tol a b d
    a=$(sl_aspect_milli "$aw" "$ah") || return 1
    b=$(sl_aspect_milli "$bw" "$bh") || return 1
    tol=${STREAM_ASPECT_TOLERANCE:-5}
    [[ "$tol" =~ ^[0-9]+$ ]] || tol=5
    d=$(( a - b )); (( d < 0 )) && d=$(( -d ))
    (( d <= tol * 10 ))
}

resolve_target_mode() {
    # Resolve a client hint against the host's advertised modes (spec §13-§18).
    # Args: CLIENT_WIDTH CLIENT_HEIGHT CLIENT_FPS. Prints "WIDTH HEIGHT REFRESH"
    # (REFRESH empty when the source cannot expose it) or returns 1 after
    # logging TARGET_MODE_NO_COMPATIBLE_HOST_MODE.
    #
    # Deterministic priority: aspect-compatible candidates only, then exact
    # resolution, then the refresh best matching the client FPS (>= FPS with a
    # clean cadence), then the smallest pixel difference, then the higher
    # refresh. A higher-pixel mode is never chosen over an exact/compatible one
    # (spec §14, §16-§18).
    local cw=$1 ch=$2 cfps=$3 tol modes best
    tol=${STREAM_ASPECT_TOLERANCE:-5}
    [[ "$tol" =~ ^[0-9]+$ ]] || tol=5
    modes=$(get_host_mode_list) || modes=""
    if [[ -z "$modes" ]]; then
        _sl_event TARGET_MODE_NO_COMPATIBLE_HOST_MODE "no host modes for ${cw}x${ch}"
        return 1
    fi
    best=$(printf '%s\n' "$modes" | awk -v cw="$cw" -v ch="$ch" -v cfps="$cfps" -v tol="$tol" '
        function abs(x) { return x < 0 ? -x : x }
        BEGIN {
            ca = int(cw * 1000 / ch)
            bestw = ""; bestexact = 0; bestscore = -1; bestpxdiff = -1; bestr = ""
        }
        {
            line = $0
            if (line !~ /^[0-9]+x[0-9]+(@[0-9]+)?$/) next
            split(line, p, "x")
            w = p[1] + 0
            rest = p[2]
            if (index(rest, "@") > 0) { split(rest, q, "@"); h = q[1] + 0; r = q[2] + 0 }
            else { h = rest + 0; r = "" }
            if (abs(int(w * 1000 / h) - ca) > tol * 10) next
            exact = (w == cw && h == ch) ? 1 : 0
            if (r == "") score = 0
            else if (cfps <= 0) score = 1
            else {
                ge = (r >= cfps) ? 1 : 0
                score = ge * 10 + ((ge && (r % cfps) == 0) ? 1 : 0)
            }
            pxdiff = abs(w * h - cw * ch)
            better = 0
            if (bestw == "") better = 1
            else if (exact > bestexact) better = 1
            else if (exact < bestexact) better = 0
            else if (score > bestscore) better = 1
            else if (score < bestscore) better = 0
            else if (pxdiff < bestpxdiff) better = 1
            else if (pxdiff > bestpxdiff) better = 0
            else if (r + 0 > bestr + 0) better = 1
            if (better) {
                bestw = w; besth = h; bestr = r
                bestexact = exact; bestscore = score; bestpxdiff = pxdiff
            }
        }
        END { if (bestw != "") printf "%d %d %s\n", bestw, besth, bestr }
    ')
    if [[ -z "$best" ]]; then
        _sl_event TARGET_MODE_NO_COMPATIBLE_HOST_MODE "${cw}x${ch}"
        return 1
    fi
    printf '%s\n' "$best"
}

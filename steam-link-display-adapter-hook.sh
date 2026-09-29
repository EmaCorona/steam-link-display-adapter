#!/usr/bin/env bash
# shellcheck shell=bash
# Gamescope/DRM integration layer.
# The main wrapper deliberately calls only these functions, so the
# environment-specific probing can be refined here without touching lifecycle
# logic.
#
# Handoff H2/H3/H7 adaptations for this Bazzite build (gamescope 3.16.28-ogc3+,
# measured 2026-09-28):
#   - mode re-poll via `gamescopectl backend_set_dirty`; the
#     GAMESCOPE_DISPLAY_MODE_NUDGE X atom is not exposed by this build.
#   - current-mode readback from the user journal: last "drm: selecting mode
#     WxH@RHz". X screen geometry and the refresh feedback atom do not represent
#     the DRM mode the session is actually scanning.
#   - mode list from GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL when present, else the
#     kernel ModeDB of the connector; the exact refresh is enforced by the
#     post-switch verification (before any screen sleep).
#   - target verification accepts the display's re-picked refresh for the same
#     resolution (dynamic modes; observed 1920x1200@60Hz -> @164Hz) via
#     STREAM_ALT_REFRESHES (default: 164).
#   - steam_link_streaming_active() (user spec 2026-09-28): the wrapper runs the
#     display pipeline only while a Steam Link session is active; detection is
#     PipeWire-based (no Gamescope dependencies).
#   - Xwayland #1 synchronization (spec 2026-09-29, ANALISI-XWAYLAND-1.md): the
#     DRM/output mode change does not move the game's Xwayland server (#1), so
#     Steam captures a mismatched geometry. The output mode and the Xwayland #1
#     mode are two distinct states, synchronized explicitly before the launch
#     via GAMESCOPE_XWAYLAND_MODE_CONTROL (see the block at the end of this
#     file for the measured mechanism).

set -Eeuo pipefail

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "ERROR: required command not found: $1"
        return 1
    }
}

_sl_streaming_signals_present() {
    local out=""
    if command -v pactl >/dev/null 2>&1; then
        out=$(pactl list short sinks 2>/dev/null || true)
        if grep -q 'steam-streaming' <<<"$out"; then
            return 0
        fi
    fi
    if command -v pw-cli >/dev/null 2>&1; then
        out=$(pw-cli ls Node 2>/dev/null || true)
        if grep -qi 'steam-streaming' <<<"$out"; then
            return 0
        fi
    fi
    return 1
}

_sl_stream_cycle_recent_journal() {
    # True when a Steam stream session started/stopped within
    # STREAM_DETECT_WINDOW_SECONDS (Steam's own journal markers, current boot,
    # identifier "steam" only — no other unit can trip this).
    local window since recent ts marker_epoch
    command -v journalctl >/dev/null 2>&1 || return 1
    window=${STREAM_DETECT_WINDOW_SECONDS:-180}
    [[ "$window" =~ ^[0-9]+$ ]] || window=180
    since=$(( $(date +%s) - window ))
    recent=$(journalctl --user -b -t steam --since "@$since" --no-pager -g 'Streaming started to|Deinitializing streaming' 2>/dev/null | tail -n1 || true)
    [[ -n "$recent" ]] || return 1
    # Double-check the marker timestamp (short journal format "Sep 28 23:29:33").
    ts=$(sed -n 's/^\([A-Z][a-z][a-z] [ 0-9][0-9] [0-9][0-9:]*\) .*/\1/p' <<<"$recent")
    [[ -n "$ts" ]] || return 1
    marker_epoch=$(date -d "$ts" +%s 2>/dev/null || printf '0')
    (( marker_epoch >= since ))
}

_sl_stream_log_recent() {
    # Same question answered from Steam's host log files, which survive a Steam
    # restart: measured 2026-09-29, after Steam restarted at 00:38:18 the user
    # journal held no "steam" stream marker for the 00:36:22-00:37:24 cycle
    # (the 180 s window was empty -> the wrapper bypassed at 00:38:38 and the
    # session streamed 21:9), while streaming_log.txt still carried both
    # markers. Union with the journal check: either source may say "recent".
    local window since f line ts newest=0 marker_epoch
    window=${STREAM_DETECT_WINDOW_SECONDS:-180}
    [[ "$window" =~ ^[0-9]+$ ]] || window=180
    since=$(( $(date +%s) - window ))
    for f in "${STEAM_STREAM_LOG:-$HOME/.local/share/Steam/logs/streaming_log.txt}" \
             "${STEAM_STREAM_LOG_PREV:-$HOME/.local/share/Steam/logs/streaming_log.previous.txt}"; do
        [[ -f "$f" ]] || continue
        line=$(grep -E 'Streaming started to|Deinitializing streaming' "$f" 2>/dev/null | tail -n1 || true)
        [[ -n "$line" ]] || continue
        # Host log format: "[2026-09-29 00:37:24][293.94...] <text>".
        ts=$(sed -n 's/^\[\([0-9][0-9-]* [0-9:]*\)\].*/\1/p' <<<"$line")
        [[ -n "$ts" ]] || continue
        marker_epoch=$(date -d "$ts" +%s 2>/dev/null || printf '0')
        (( marker_epoch > newest )) && newest=$marker_epoch
    done
    (( newest >= since ))
}

_sl_stream_cycle_recent() {
    # Historical marker (journal + Steam host log). DIAGNOSTIC ONLY since the
    # 2026-09-29 first-connection spec: it must never be a precondition for the
    # detection window, because on a first connection no marker exists yet.
    _sl_stream_cycle_recent_journal && return 0
    _sl_stream_log_recent && return 0
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

_sl_sink_present() {
    _sl_streaming_signals_present
}

_sl_stream_history_marker() {
    # Diagnostic only (spec §4).
    if _sl_stream_cycle_recent; then printf 'recent'; else printf 'none'; fi
}

_sl_have_sink_query_tool() {
    command -v pactl >/dev/null 2>&1 || command -v pw-cli >/dev/null 2>&1
}

_sl_gamescope_session_available() {
    # True when a Gamescope session is reachable. Used only as the negative gate
    # for the detection window in Desktop Mode (spec §17: immediate direct
    # launch); it is never taken as proof of a Steam Link session (spec §8).
    command -v gamescopectl >/dev/null 2>&1 || return 1
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl 2>/dev/null | grep -q 'Connector Name:'
}

_sl_wait_for_stream_signal() {
    # Bounded, event-driven detection of a NEW Steam Link session (spec §5-§7):
    # the sink is absent, so observe its creation as an event. `pactl subscribe`
    # reacts almost immediately; the real sink state is re-verified after every
    # event AND after every poll expiry, so a lost event or a dead subscriber
    # cannot hide a live session (spec §6). No historical marker involved.
    local max_wait=$1 deadline now remaining chunk chunk_s
    deadline=$(( $(date +%s%N) / 1000000 + max_wait * 1000 ))
    if command -v pactl >/dev/null 2>&1; then
        while :; do
            now=$(( $(date +%s%N) / 1000000 ))
            if (( now >= deadline )); then break; fi
            remaining=$(( deadline - now ))
            chunk=${_SL_SUBSCRIBE_CHUNK_MS:-500}
            [[ "$chunk" =~ ^[0-9]+$ ]] || chunk=500
            if (( remaining < chunk )); then chunk=$remaining; fi
            chunk_s=$(printf '%d.%03d' $(( chunk / 1000 )) $(( chunk % 1000 )))
            while IFS= read -r line; do
                case "$line" in
                    *sink*|*server*)
                        if _sl_sink_present; then
                            _sl_event STREAM_SIGNAL_EVENT 'steam-streaming-playback'
                            return 0
                        fi
                        ;;
                esac
            done < <(timeout "$chunk_s" pactl subscribe 2>/dev/null || true)
            if _sl_sink_present; then
                _sl_event STREAM_SIGNAL_EVENT 'steam-streaming-playback'
                return 0
            fi
        done
    else
        # No event source available: bounded polling that still re-verifies the
        # real sink state (never the mere receipt of an event).
        while :; do
            if _sl_sink_present; then return 0; fi
            now=$(( $(date +%s%N) / 1000000 ))
            if (( now >= deadline )); then break; fi
            sleep "${POLL_INTERVAL_SECONDS:-0.10}"
        done
    fi
    return 1
}

steam_link_streaming_active() {
    # Reliable, Gamescope-independent detection of an active Steam Link/Remote
    # Play session: for the whole duration of a stream the host loads a
    # "steam-streaming-playback" PipeWire sink (plus matching nodes) and unloads
    # it at the end (measured 2026-09-28 from Steam logs/journal).
    #
    # Three states are distinguished (spec §4): STREAM ACTIVE (sink present),
    # STREAM STARTING (no sink -> observe the creation event, bounded window),
    # NO STREAM. The window no longer depends on a previous session: on a first
    # connection no marker exists, and the wrapper still reacts to the new sink
    # (spec §5, §14, §16).
    #
    # Launch race (measured 2026-09-28): when the game is launched towards a
    # live client, the host (re)establishes the session ~1-2 s AFTER the game
    # command starts; the bounded window catches it.
    local max_wait
    max_wait=${STREAM_DETECT_WAIT_SECONDS:-5}
    [[ "$max_wait" =~ ^[0-9]+$ ]] || max_wait=5

    if _sl_sink_present; then
        _sl_event STREAM_SIGNAL_CURRENT 'steam-streaming-playback'
        return 0
    fi

    # No sink and no way to observe one: nothing to detect.
    _sl_have_sink_query_tool || return 1

    # Desktop Mode / no Gamescope session: this pipeline cannot run there and no
    # window is opened, so the local launch stays immediate (spec §17). The
    # presence of gamescope tooling is never read as proof of a session (§8).
    if [[ "${STREAM_DETECT_WINDOW_GAMESCOPE_ONLY:-1}" == 1 ]] && ! _sl_gamescope_session_available; then
        _sl_event STREAM_NO_GAMESCOPE_SESSION
        return 1
    fi

    _sl_event STREAM_WAIT_START "${max_wait}s marker=$(_sl_stream_history_marker)"
    log "Steam Link: no session yet; waiting up to ${max_wait}s for a new session"
    if _sl_wait_for_stream_signal "$max_wait"; then
        _sl_event STREAM_SIGNAL_CONFIRMED 'steam-streaming-playback'
        return 0
    fi
    log "Steam Link: no new session within ${max_wait}s"
    return 1
}

xprop_root_get() {
    local atom=$1
    [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]] || return 1
    DISPLAY="${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" xprop -root "$atom" 2>/dev/null
}

get_gamescope_info() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl 2>/dev/null
}

get_connector_name() {
    get_gamescope_info | awk -F': ' '/Connector Name:/ {print $2; exit}'
}

get_display_make() {
    get_gamescope_info | awk -F': ' '/Display Make:/ {print $2; exit}'
}

get_display_model() {
    get_gamescope_info | awk -F': ' '/Display Model:/ {print $2; exit}'
}

get_display_description() {
    local make model
    make=$(get_display_make || true)
    model=$(get_display_model || true)
    [[ -n "$make" && -n "$model" ]] || return 1
    printf '%s %s' "$make" "$model"
}

get_gamescope_mode_list() {
    local raw list
    raw=$(xprop_root_get GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL) || return 1
    # Example: GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL(STRING) = "3440x1440@165 1920x1200@60"
    list=$(sed -n 's/.*= *"\(.*\)"/\1/p' <<<"$raw")
    [[ -n "$list" ]] || return 1
    printf '%s\n' "$list"
}

# --- Dynamic client resolution (spec: risoluzione Gamescope dinamica) --------
#
# The stream geometry is no longer a constant: Steam writes the client capture
# ceiling in its host log ("Maximum capture: WxH FPS") a few ms before creating
# the streaming sink, and the wrapper turns that hint into a runtime target
# (TARGET_WIDTH/HEIGHT/REFRESH), resolved against the modes the host really
# advertises. The configured STREAM_* values remain the fallback.

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

get_host_mode_list() {
    # Mode candidates the host really advertises, one "WxH" or "WxH@R" per line.
    # Sources in order (spec §12): Gamescope X atom, modes.cfg, kernel ModeDB.
    local list line mode found=0 modes_file f
    if list=$(get_gamescope_mode_list) && [[ -n "$list" ]]; then
        printf '%s\n' "$list" | tr ' ' '\n' | grep -E '^[0-9]+x[0-9]+(@[0-9]+)?$' | sort -u
        return 0
    fi
    modes_file="${MODES_FILE:-$HOME/.config/gamescope/modes.cfg}"
    if [[ -f "$modes_file" ]]; then
        while IFS= read -r line; do
            mode=$(sed -n 's/^[^:]*:\([0-9]\+x[0-9]\+@[0-9]\+\).*/\1/p' <<<"$line")
            [[ -n "$mode" ]] && { printf '%s\n' "$mode"; found=1; }
        done <"$modes_file"
    fi
    for f in ${DRM_MODES_GLOB:-/sys/class/drm/card*-${CONNECTOR:-}/modes}; do
        [[ -f "$f" ]] || continue
        while IFS= read -r mode; do
            [[ "$mode" =~ ^[0-9]+x[0-9]+$ ]] && { printf '%s\n' "$mode"; found=1; }
        done <"$f"
    done
    (( found )) && return 0
    return 1
}

mode_list_contains() {
    local wanted=$1 list line mode res f modes_file
    if list=$(get_gamescope_mode_list) && [[ -n "$list" ]]; then
        tr ' ' '\n' <<<"$list" | grep -Fxq "$wanted"
        return $?
    fi
    # No X atom on this build: check modes.cfg, then fall back to the kernel
    # ModeDB of the connector. The refresh cannot be read back from the ModeDB;
    # the exact target refresh is proven by the post-switch verification before
    # any screen sleep.
    modes_file="${MODES_FILE:-$HOME/.config/gamescope/modes.cfg}"
    if [[ -f "$modes_file" ]]; then
        while IFS= read -r line; do
            mode=$(sed -n 's/^[^:]*:\([0-9]\+x[0-9]\+@[0-9]\+\).*/\1/p' <<<"$line")
            [[ "$mode" == "$wanted" ]] && return 0
        done <"$modes_file"
    fi
    log "mode list: Gamescope X atom unavailable; checking kernel ModeDB for $CONNECTOR"
    res=${wanted%@*}
    for f in ${DRM_MODES_GLOB:-/sys/class/drm/card*-$CONNECTOR/modes}; do
        [[ -f "$f" ]] || continue
        if grep -qx -- "$res" "$f"; then
            return 0
        fi
    done
    return 1
}

get_latest_stream_capture_hint() {
    # Read the most recent client capture hint from Steam's host log.
    # Prints "WIDTH HEIGHT FPS" on success (exit 0); returns 1 with no output
    # when the hint is unavailable or older than
    # STREAM_CAPTURE_HINT_MAX_AGE_SECONDS. The hint belongs to the CURRENT
    # session only: freshness (never STREAM_DETECT_WINDOW_SECONDS) decides, so
    # a previous session's line cannot leak into a new client (spec §4, §28).
    local max_age=${STREAM_CAPTURE_HINT_MAX_AGE_SECONDS:-10}
    [[ "$max_age" =~ ^[0-9]+$ ]] || max_age=10
    local now f line w h fps ts ts_epoch age stale=0
    now=$(date +%s)
    for f in "${STEAM_STREAM_LOG:-$HOME/.local/share/Steam/logs/streaming_log.txt}" \
             "${STEAM_STREAM_LOG_PREV:-$HOME/.local/share/Steam/logs/streaming_log.previous.txt}"; do
        [[ -f "$f" ]] || continue
        # Scan the tail in reverse order: the first valid line wins.
        while IFS= read -r line; do
            [[ "$line" == *"Maximum capture:"* ]] || continue
            w=$(sed -n 's/.*Maximum capture: *\([0-9]\+\)x\([0-9]\+\) .*/\1/p' <<<"$line")
            h=$(sed -n 's/.*Maximum capture: *\([0-9]\+\)x\([0-9]\+\) .*/\2/p' <<<"$line")
            fps=$(sed -n 's/.*Maximum capture: *[0-9]\+x[0-9]\+ \([0-9][0-9.]*\) *FPS.*/\1/p' <<<"$line")
            [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && -n "$fps" ]] || continue
            ts=$(sed -n 's/^\[\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\)\].*/\1/p' <<<"$line")
            [[ -n "$ts" ]] || continue
            ts_epoch=$(date -d "$ts" +%s 2>/dev/null || true)
            [[ -n "$ts_epoch" ]] || continue
            age=$(( now - ts_epoch ))
            (( age < 0 )) && age=0
            if (( age > max_age )); then stale=1; continue; fi
            fps=$(awk -v v="$fps" 'BEGIN { printf "%d", v + 0.5 }')
            _sl_event CLIENT_HINT "${w}x${h}@${fps}"
            printf '%s %s %s\n' "$w" "$h" "$fps"
            return 0
        done < <(tail -c 262144 -- "$f" 2>/dev/null | awk '{a[NR]=$0} END {for (i=NR;i>=1;i--) print a[i]}')
    done
    if (( stale )); then _sl_event CLIENT_HINT stale; else _sl_event CLIENT_HINT unavailable; fi
    return 1
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

get_current_mode() {
    require_cmd journalctl || return 1
    local line mode
    # Read the DRM mode from the session log. X geometry/refresh atoms are not
    # reliable for this on the current build.
    line=$(journalctl --user -b --no-pager -g 'selecting mode [0-9]' 2>/dev/null | tail -n 1 || true)
    [[ -n "$line" ]] || return 1
    mode=$(sed -n 's/.*selecting mode \([0-9]\+x[0-9]\+\)@\([0-9]\+\)Hz.*/\1@\2/p' <<<"$line")
    [[ -n "$mode" ]] || return 1
    printf '%s\n' "$mode"
}

is_target_mode_active() {
    local current r res
    res="${TARGET_WIDTH:-$STREAM_WIDTH}x${TARGET_HEIGHT:-$STREAM_HEIGHT}"
    current=$(get_current_mode 2>/dev/null || true)
    [[ -n "$current" ]] || return 1
    if [[ "$current" == "${res}@${TARGET_REFRESH:-$STREAM_REFRESH}" ]]; then
        return 0
    fi
    # With dynamic external modes enabled, gamescope re-picks the display's
    # highest refresh for the same resolution right after the switch (observed
    # on this build: 1920x1200@60Hz -> @164Hz within ~1s). Same resolution =>
    # same stream geometry; accept the configured alternates.
    for r in ${STREAM_ALT_REFRESHES:-164}; do
        if [[ "$current" == "${res}@${r}" ]]; then
            return 0
        fi
    done
    return 1
}

is_local_mode_active() {
    local expected="${LOCAL_WIDTH}x${LOCAL_HEIGHT}@${LOCAL_REFRESH}"
    [[ "$(get_current_mode 2>/dev/null || true)" == "$expected" ]]
}

set_dynamic_modes_allowed() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl drm_allow_dynamic_modes_for_external_display "$1" >/dev/null
}

screen_sleep() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl drm_sleep_external_screen 1 >/dev/null
}

screen_wake() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl drm_sleep_external_screen 0 >/dev/null
}

nudge_mode() {
    require_cmd gamescopectl || return 1
    # Re-poll the backend so gamescope re-runs connector setup and picks up the
    # saved mode written to modes.cfg. Polling/verification always follows; a
    # nudge alone is never considered sufficient.
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl backend_set_dirty >/dev/null
}

wait_for_target_mode() {
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if is_target_mode_active; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_local_mode() {
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if is_local_mode_active; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

# --- Xwayland #1 synchronization (Steam Link virtual display) ---------------
#
# Mechanism measured 2026-09-29 on gamescope 3.16.28-ogc3+ (nested instance,
# --xwayland-count 2, Desktop Mode) and valid for the Gaming Mode session:
#
#   * every Xwayland root carries GAMESCOPE_XWAYLAND_SERVER_ID = its Gamescope
#     server index, so the DISPLAY <-> index mapping is discovered at runtime and
#     never assumed: the numeric display does NOT equal the index (probe:
#     DISPLAY :1 -> id 0, DISPLAY :2 -> id 1).
#   * writing the root property
#         GAMESCOPE_XWAYLAND_MODE_CONTROL = [server_idx, width, height, allowSuperRes]
#     (xprop -f ... 32c -set "1, 1024, 768, 0") makes gamescope call
#         wlserver_set_xwayland_server_mode(server_idx, w, h, g_nOutputRefresh)
#     (journal: "wlserver: Updating mode for xwayland server #1: 1024x768@60")
#     and the target root window really changes size. The write works on the
#     server's own root and on the UI server's root (gamescope routes by idx).
#   * gamescope deletes the property once handled, so the property readback is
#     never the confirmation -- the target root-window geometry is.
#
# `xprop` needs the right DISPLAY (and XAUTHORITY, inherited from the launch
# environment) for each candidate server.

declare -A XWAYLAND_DISPLAY_CACHE=()

xwayland_candidate_displays() {
    local s i d
    printf '%s\n' "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}"
    printf '%s\n' "${DISPLAY:-}"
    for s in /tmp/.X11-unix/X*; do
        [[ -e "$s" ]] || continue
        printf ':%s\n' "${s##*X}"
    done
    for d in ${XWAYLAND_EXTRA_DISPLAYS:-}; do
        [[ -n "$d" ]] && printf '%s\n' "$d"
    done
    for ((i = 0; i <= ${XWAYLAND_SCAN_MAX:-9}; i++)); do
        printf ':%s\n' "$i"
    done
    return 0
}

xwayland_server_id_for_display() {
    local display=$1 raw id
    [[ -n "$display" ]] || return 1
    raw=$(DISPLAY="$display" xprop -root GAMESCOPE_XWAYLAND_SERVER_ID 2>/dev/null) || return 1
    id=$(sed -n 's/.*= *\([0-9][0-9]*\).*/\1/p' <<<"$raw")
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$id"
}

xwayland_display_for_server() {
    local want=$1 display id seen=' '
    if [[ -n "${XWAYLAND_DISPLAY_CACHE[$want]:-}" ]]; then
        printf '%s\n' "${XWAYLAND_DISPLAY_CACHE[$want]}"
        return 0
    fi
    while IFS= read -r display; do
        [[ -n "$display" ]] || continue
        [[ "$seen" == *" $display "* ]] && continue
        seen+="$display "
        id=$(xwayland_server_id_for_display "$display") || continue
        XWAYLAND_DISPLAY_CACHE[$id]=$display
        if [[ "$id" == "$want" ]]; then
            printf '%s\n' "$display"
            return 0
        fi
    done < <(xwayland_candidate_displays)
    return 1
}

get_xwayland_root_size() {
    local display=$1 size
    require_cmd xdpyinfo || return 1
    [[ -n "$display" ]] || return 1
    size=$(DISPLAY="$display" xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
    [[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || return 1
    printf '%s\n' "$size"
}

get_xwayland_server_mode() {
    local display
    display=$(xwayland_display_for_server "$1") || return 1
    get_xwayland_root_size "$display"
}

xwayland_server_present() {
    xwayland_display_for_server "$1" >/dev/null 2>&1
}

set_xwayland_server_mode() {
    local idx=$1 width=$2 height=$3 allow_super_res=${4:-0} display
    require_cmd xprop || return 1
    display=$(xwayland_display_for_server "$idx") \
        || display=$(xwayland_display_for_server 0) \
        || display="${GAMESCOPE_DISPLAY:-${DISPLAY:-}}"
    [[ -n "$display" ]] || return 1
    DISPLAY="$display" xprop -root -f GAMESCOPE_XWAYLAND_MODE_CONTROL 32c \
        -set GAMESCOPE_XWAYLAND_MODE_CONTROL "${idx}, ${width}, ${height}, ${allow_super_res}" \
        >/dev/null 2>&1
}

set_stream_xwayland_mode() {
    # Uses the runtime target resolved from the client hint, not the static
    # stream config (spec §21-§22): Xwayland #1 must match the output geometry.
    set_xwayland_server_mode "${STREAM_XWAYLAND_SERVER_INDEX:-1}" \
        "${TARGET_WIDTH:-$STREAM_WIDTH}" "${TARGET_HEIGHT:-$STREAM_HEIGHT}" "${STREAM_XWAYLAND_ALLOW_SUPERRES:-0}"
}

verify_stream_xwayland_mode() {
    local want="${TARGET_WIDTH:-$STREAM_WIDTH}x${TARGET_HEIGHT:-$STREAM_HEIGHT}" got
    got=$(get_xwayland_server_mode "${STREAM_XWAYLAND_SERVER_INDEX:-1}" 2>/dev/null || true)
    [[ "$got" == "$want" ]]
}

wait_for_stream_xwayland_mode() {
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if verify_stream_xwayland_mode; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

restore_stream_xwayland_mode() {
    local idx="${STREAM_XWAYLAND_SERVER_INDEX:-1}"
    local want="${LOCAL_WIDTH}x${LOCAL_HEIGHT}" deadline got
    xwayland_display_for_server "$idx" >/dev/null 2>&1 || return 0
    set_xwayland_server_mode "$idx" "$LOCAL_WIDTH" "$LOCAL_HEIGHT" 0 || return 1
    deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        got=$(get_xwayland_server_mode "$idx" 2>/dev/null || true)
        [[ "$got" == "$want" ]] && return 0
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

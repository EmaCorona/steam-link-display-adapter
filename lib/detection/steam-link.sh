#!/usr/bin/env bash
# shellcheck shell=bash
# Steam Link / Remote Play session detection (read-only).
#
# The display pipeline runs only while a Steam Link session is active; for the
# whole duration of a stream the host loads a "steam-streaming-playback"
# PipeWire sink (plus matching nodes) and unloads it at the end. Detection is
# event-driven and never modifies the environment.

set -Eeuo pipefail

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

    _sl_event STREAM_WAIT_START "${max_wait}s marker=$(_sl_stream_history_marker)"
    log "Steam Link: no session yet; waiting up to ${max_wait}s for a new session"
    if _sl_wait_for_stream_signal "$max_wait"; then
        _sl_event STREAM_SIGNAL_CONFIRMED 'steam-streaming-playback'
        return 0
    fi
    log "Steam Link: no new session within ${max_wait}s"
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

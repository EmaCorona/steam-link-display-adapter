#!/usr/bin/env bash
# run-tests.sh - hardware-free test suite for the steam-link-display-adapter wrapper.
#
# Runs entirely in a throwaway sandbox: HOME/XDG_* are redirected to a temp dir
# and gamescopectl/xprop/xdpyinfo/journalctl are stub binaries on PATH. No real
# display, gamescope session, Steam or game is touched.
#
# Usage: bash tests/run-tests.sh [name-filter]
# Exit code: 0 = all pass, 1 = at least one failure.
set -u

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKG_DIR=$(cd -- "$TESTS_DIR/.." && pwd)
WRAPPER="$PKG_DIR/bin/steam-link-display-adapter.sh"
RESTORE="$PKG_DIR/bin/steam-link-display-adapter-restore.sh"
LIB="$PKG_DIR/lib"
STUBS="$TESTS_DIR/stubs"
BASE_PATH="$PATH"
FILTER=${1:-}

# The old project/namespace tokens are assembled at runtime on purpose: this
# suite scans the whole repository for them, so the file must not contain any
# literal occurrence. See rename_repo_namespace_clean.
LEG_PROJ="steam-link-virtual""-display"
LEG_BRAND="steamlink""-display"

PASS=0
FAIL=0
FAILED=()
RUNNING=""

say_pass() { PASS=$((PASS + 1)); printf 'ok   %-26s %s\n' "$RUNNING" "$1"; }
say_fail() { FAIL=$((FAIL + 1)); FAILED+=("$RUNNING :: $1"); printf 'FAIL %-26s %s\n' "$RUNNING" "$1"; }

eq() { local d=$1 a=$2 b=$3; if [[ "$a" == "$b" ]]; then say_pass "$d"; else say_fail "$d (got '$a' want '$b')"; fi; }
ne() { local d=$1 a=$2 b=$3; if [[ "$a" != "$b" ]]; then say_pass "$d"; else say_fail "$d (got '$a', expected different)"; fi; }
exists() { local d=$1 f=$2; if [[ -e "$f" ]]; then say_pass "$d"; else say_fail "$d (missing ${f##*/})"; fi; }
absent() { local d=$1 f=$2; if [[ -e "$f" ]]; then say_fail "$d (${f##*/} exists)"; else say_pass "$d"; fi; }
file_has() { local d=$1 f=$2 p=$3; if [[ -f "$f" ]] && grep -q -- "$p" "$f"; then say_pass "$d"; else say_fail "$d (no '$p' in ${f##*/})"; fi; }
file_lacks() { local d=$1 f=$2 p=$3; if [[ -f "$f" ]] && grep -q -- "$p" "$f"; then say_fail "$d ('$p' found in ${f##*/})"; else say_pass "$d"; fi; }
cmp_file() { local d=$1 f=$2 e=$3 got; got=$(cat "$f" 2>/dev/null); if [[ "$got" == "$e" ]]; then say_pass "$d"; else say_fail "$d (got '$got' want '$e')"; fi; }

SANDBOX=""
RC=0
STDOUT=""; STDERR=""; LOG=""; STATE_DIR=""; BACKUP=""; LOCKF=""; MODESF=""; CFG=""

begin() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/slvd-test.XXXXXX")
  export SANDBOX
  export HOME="$SANDBOX/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_STATE_HOME="$HOME/.local/state"
  export STUB_STATE_DIR="$SANDBOX/stub"
  export PATH="$STUBS:$BASE_PATH"
  export DISPLAY=:99
  export GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  export XWAYLAND_EXTRA_DISPLAYS=":98"
  export STUB_XWL1_DISPLAY=:98
  export STUB_XWL0_DISPLAY=:99
  unset STUB_SET_DIRTY_NOOP STUB_SET_DIRTY_FAIL STUB_SLEEP_FAIL STUB_WAKE_FAIL STUB_ALLOW_FAIL STUB_CONNECTOR STUB_NO_INFO STUB_REPICK_REFRESH STUB_STREAM_ACTIVE STUB_XWL_FAIL STUB_XWL_NOOP STUB_XWL1_ABSENT DRM_MODES_GLOB 2>/dev/null || true
  unset STREAM_MODE STREAM_CAPTURE_HINT_MAX_AGE_SECONDS STREAM_NO_COMPATIBLE_FALLBACK STREAM_ASPECT_TOLERANCE STEAM_STREAM_LOG STEAM_STREAM_LOG_PREV LOCAL_WIDTH LOCAL_HEIGHT LOCAL_REFRESH STREAM_ALT_REFRESHES 2>/dev/null || true
  export STUB_STREAM_ACTIVE=1
  mkdir -p "$HOME/.config/gamescope" "$XDG_CONFIG_HOME/steam-link-display-adapter" "$XDG_STATE_HOME/steam-link-display-adapter" "$STUB_STATE_DIR"
  STATE_DIR="$XDG_STATE_HOME/steam-link-display-adapter"
  BACKUP="$STATE_DIR/modes.cfg.backup"
  LOCKF="$STATE_DIR/lock"
  MODESF="$HOME/.config/gamescope/modes.cfg"
  CFG="$XDG_CONFIG_HOME/steam-link-display-adapter/config"
  LOG="$STATE_DIR/wrapper.log"
  STDOUT="$SANDBOX/stdout"
  STDERR="$SANDBOX/stderr"
  printf 'StubMake StubModel:3440x1440@165 0\n' >"$MODESF"
  printf '3440x1440@165\n' >"$STUB_STATE_DIR/mode"
  printf '3440x1440\n' >"$STUB_STATE_DIR/xwl1_mode"
  printf 'drm: selecting mode 3440x1440@165Hz\n' >"$STUB_STATE_DIR/journal"
  : >"$STUB_STATE_DIR/dynamic.log"
  : >"$STUB_STATE_DIR/sleep.log"
  RC=0
}

end() { if [[ -n "$SANDBOX" && -d "$SANDBOX" ]]; then rm -rf "$SANDBOX"; fi; SANDBOX=""; }

run_wrapper() { bash "$WRAPPER" "$@" >"$STDOUT" 2>"$STDERR"; RC=$?; }

seed_stale_state() {
  local omode=${1:-3440x1440@165} oxwl=${2:-3440x1440}
  printf 'StubMake StubModel:1920x1200@60\n' >"$MODESF"
  printf '1920x1200@60\n' >"$STUB_STATE_DIR/mode"
  printf '1920x1200\n' >"$STUB_STATE_DIR/xwl1_mode"
  printf 'drm: selecting mode 1920x1200@60Hz\n' >>"$STUB_STATE_DIR/journal"
  printf 'StubMake StubModel:%s 0\n' "$omode" >"$BACKUP"
  {
    printf 'VERSION=1\n'
    printf 'PHASE=STREAMING\n'
    printf 'MODES_BACKUP=%s\n' "$BACKUP"
    printf 'MODES_EXISTED=1\n'
    printf 'SCREEN_SLEEP_REQUESTED=1\n'
    printf 'XWAYLAND_SYNCED=1\n'
    printf 'ORIGINAL_CONNECTOR=DP-3\n'
    printf 'ORIGINAL_MODE=%s\n' "$omode"
    printf 'ORIGINAL_XWAYLAND_MODE=%s\n' "$oxwl"
    printf 'DISPLAY_DESCRIPTION=StubMake StubModel\n'
  } >"$STATE_DIR/state"
}

# State written by a build that predates the XWAYLAND_SYNCED field.
seed_stale_state_old_format() {
  seed_stale_state
  grep -v '^XWAYLAND_SYNCED=' "$STATE_DIR/state" >"$STATE_DIR/state.tmp"
  mv "$STATE_DIR/state.tmp" "$STATE_DIR/state"
}

# State written by a build that predates the host profile fields: the recovery
# may still complete via the legacy LOCAL_* configuration (spec §17).
seed_stale_state_no_profile() {
  seed_stale_state
  grep -vE '^(ORIGINAL_|DISPLAY_DESCRIPTION=)' "$STATE_DIR/state" >"$STATE_DIR/state.tmp"
  mv "$STATE_DIR/state.tmp" "$STATE_DIR/state"
}

# Parametric host fixture (spec §39): connector, native mode and advertised
# mode list. Simulates a different physical host without touching the code;
# the default sandbox is host A (3440x1440@165 on DP-3).
set_host() {
  local connector=$1 mode=$2 list=${3:-}
  [[ -n "$list" ]] || list=$mode
  export STUB_CONNECTOR="$connector"
  export STUB_MODE_LIST="$list"
  printf '%s\n' "$mode" >"$STUB_STATE_DIR/mode"
  printf 'drm: selecting mode %sHz\n' "$mode" >"$STUB_STATE_DIR/journal"
  printf '%s\n' "${mode%@*}" >"$STUB_STATE_DIR/xwl1_mode"
  printf 'StubMake StubModel:%s 0\n' "$mode" >"$MODESF"
}

# Source the library in a throwaway shell and call one of its functions.
hook_fn() {
  local fn=$1; shift
  bash -c 'LIB_ROOT="$1"; shift; source "$LIB_ROOT/core/bootstrap.sh"; fn="$1"; shift; "$fn" "$@"' \
    _ "$LIB" "$fn" "$@" 2>/dev/null
}

# Like hook_fn, but keeps only the numeric result line (the hook also emits
# human log lines on stdout when not sourced by the wrapper).
hook_num() {
  hook_fn "$@" | grep -E '^[0-9]+ [0-9]+ [0-9]+$' | tail -n1
}

# Append a Steam host log line "Maximum capture: WxH FPS" with a timestamp
# `age` seconds in the past.
steam_hint() {
  local f=$1 age=$2 text=$3
  printf '[%s][293.94] %s\n' "$(date -d "@$(( $(date +%s) - age ))" '+%Y-%m-%d %H:%M:%S')" "$text" >>"$f"
}

# Point the wrapper/hook at a sandbox Steam log for the current test.
use_steam_log() {
  export STEAM_STREAM_LOG="$SANDBOX/steam.log"
  export STEAM_STREAM_LOG_PREV="$SANDBOX/steam.previous.log"
  : >"$STEAM_STREAM_LOG"
}

test_happy_path() {
  begin
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "exit code 0" "$RC" 0
  cmp_file "modes.cfg restored to original" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "state file cleared" "$STATE_DIR/state"
  absent "snapshot removed" "$BACKUP"
  file_has "target mode verified" "$LOG" "Verified target mode: 1920x1200@60"
  file_has "steam link detected" "$LOG" "Steam Link streaming session detected"
  file_has "xwayland1 sync requested" "$LOG" "XWAYLAND1_SYNC_REQUESTED 1/1920/1200/0"
  file_has "xwayland1 sync confirmed" "$LOG" "XWAYLAND1_SYNC_CONFIRMED 1920x1200"
  file_has "xwayland1 restored" "$LOG" "Xwayland #1 restored to 3440x1440"
  file_has "original mode re-verified" "$LOG" "Verified original mode: 3440x1440@165"
  file_has "host profile captured" "$LOG" "HOST_PROFILE_DETECTED connector=DP-3 mode=3440x1440@165 xwayland=3440x1440"
  file_has "warm-up re-poll sent" "$LOG" "Warm-up re-poll sent"
  file_has "game launched" "$LOG" "Launching game:"
  file_has "game launch event" "$LOG" "GAME_LAUNCH"
  file_has "screen slept" "$STUB_STATE_DIR/sleep.log" '^1$'
  file_has "screen woken" "$STUB_STATE_DIR/sleep.log" '^0$'
  eq "dynamic modes cycle 1,1,0" "$(cat "$STUB_STATE_DIR/dynamic.log")" $'1\n1\n0'
  eq "cleanup ran once" "$(grep -c 'Cleanup finished' "$LOG" 2>/dev/null)" 1
  eq "last DRM mode is local" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode 3440x1440@165Hz"
  cmp_file "xwayland #1 back to local geometry" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
}

test_config_invalid() {
  begin
  printf 'STREAM_HEIGHT=1080\n' >"$CFG"
  run_wrapper true
  ne "refuses inconsistent aspect/geometry" "$RC" 0
  file_has "aspect error logged" "$LOG" "STREAM_ASPECT must match"
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  file_lacks "game not started" "$LOG" "Launching game:"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
}

test_config_invalid_aspect() {
  begin
  printf "STREAM_ASPECT='21:9'\n" >"$CFG"
  run_wrapper true
  ne "refuses 21:9 for a 16:10 geometry" "$RC" 0
  file_has "aspect error logged" "$LOG" "STREAM_ASPECT must match"
}

test_precheck_mode_missing() {
  begin
  export STUB_MODE_LIST="3440x1440@165"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  ne "fails when target not advertised" "$RC" 0
  file_has "mode error logged" "$LOG" "does not currently advertise 1920x1200@60"
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
}

test_precheck_connector_mismatch() {
  begin
  printf "CONNECTOR='DP-3'\n" >"$CFG"
  export STUB_CONNECTOR=DP-4
  run_wrapper true
  ne "fails on connector mismatch" "$RC" 0
  file_has "connector error logged" "$LOG" "Gamescope connector is 'DP-4', expected 'DP-3'"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
}

test_precheck_kernel_fallback_ok() {
  begin
  unset STUB_MODE_LIST
  mkdir -p "$SANDBOX/drmsys"
  printf '3440x1440\n1920x1200\n' >"$SANDBOX/drmsys/drm-modes-DP-3"
  export DRM_MODES_GLOB="$SANDBOX/drmsys/drm-modes-*"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "proceeds via kernel ModeDB fallback" "$RC" 0
  file_has "fallback logged" "$LOG" "checking kernel ModeDB for DP-3"
}

test_precheck_kernel_fallback_missing() {
  begin
  unset STUB_MODE_LIST
  mkdir -p "$SANDBOX/drmsys"
  printf '3440x1440\n1920x1080\n' >"$SANDBOX/drmsys/drm-modes-DP-3"
  export DRM_MODES_GLOB="$SANDBOX/drmsys/drm-modes-*"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  ne "fails when kernel ModeDB lacks the mode" "$RC" 0
  file_has "mode error logged" "$LOG" "does not currently advertise 1920x1200@60"
}

test_switch_timeout() {
  begin
  export STUB_SET_DIRTY_NOOP=1
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  printf 'MODE_TIMEOUT_SECONDS=1\n' >"$CFG"
  run_wrapper true
  ne "fails when mode never changes" "$RC" 0
  file_has "timeout logged" "$LOG" "target mode not reached within 1s"
  file_lacks "game not started" "$LOG" "Launching game:"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  cmp_file "modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "state cleared" "$STATE_DIR/state"
}

test_switch_command_failure() {
  begin
  export STUB_SET_DIRTY_FAIL=1
  run_wrapper true
  ne "fails when re-poll command fails" "$RC" 0
  file_has "nudge failure logged" "$LOG" "mode re-poll failed"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
}

test_sleep_failure() {
  begin
  export STUB_SLEEP_FAIL=1
  run_wrapper true
  ne "fails when screen sleep fails" "$RC" 0
  file_has "sleep failure logged" "$LOG" "failed to put the external screen to sleep"
  file_has "wake still attempted" "$STUB_STATE_DIR/sleep.log" '^0$'
  file_lacks "game not started" "$LOG" "Launching game:"
}

test_exit_code_preserved() {
  begin
  run_wrapper bash -c 'exit 42'
  eq "exit 42 propagated" "$RC" 42
  cmp_file "modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "state cleared" "$STATE_DIR/state"
}

test_lock_contention() {
  begin
  : >"$LOCKF"
  flock -n "$LOCKF" -c 'sleep 2' &
  local holder=$!
  sleep 0.5
  run_wrapper true
  eq "second instance refused" "$RC" 73
  file_has "lock message" "$STDERR" "another instance is already active"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

test_stale_state_recovery() {
  begin
  seed_stale_state
  run_wrapper true
  eq "recovered and ran" "$RC" 0
  file_has "recovery completed" "$LOG" "Stale-state recovery complete"
  file_has "saved run profile logged" "$LOG" "Saved run profile: connector=DP-3 mode=3440x1440@165 xwayland=3440x1440"
  file_has "recovered original mode verified" "$LOG" "Verified original mode: 3440x1440@165"
  cmp_file "modes.cfg = local after run" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "state cleared" "$STATE_DIR/state"
  file_has "wake during recovery" "$STUB_STATE_DIR/sleep.log" '^0$'
  eq "last DRM mode is local" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode 3440x1440@165Hz"
}

test_signals() {
  local sig want wp rc gpid i
  for pair in "TERM 143" "INT 130" "HUP 129"; do
    set -- $pair; sig=$1; want=$2
    begin
    set -m
    bash "$WRAPPER" sleep 30 >"$STDOUT" 2>"$STDERR" &
    wp=$!
    set +m
    i=0
    while (( i < 150 )); do
      if [[ -f "$LOG" ]] && grep -q "Game PID:" "$LOG"; then break; fi
      sleep 0.1; i=$((i + 1))
    done
    kill -"$sig" "$wp" 2>/dev/null
    wait "$wp" 2>/dev/null
    rc=$?
    eq "SIG$sig exit code" "$rc" "$want"
    cmp_file "SIG$sig modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
    absent "SIG$sig state cleared" "$STATE_DIR/state"
    file_has "SIG$sig screen woken" "$STUB_STATE_DIR/sleep.log" '^0$'
    gpid=$(sed -n 's/.*Game PID: \([0-9]*\).*/\1/p' "$LOG" 2>/dev/null | tail -n 1)
    if [[ -n "$gpid" ]]; then kill "$gpid" 2>/dev/null || true; fi
    end
  done
}

test_restore_helper() {
  begin
  seed_stale_state
  bash "$RESTORE" >"$STDOUT" 2>"$STDERR"
  RC=$?
  eq "restore helper exit 0" "$RC" 0
  file_has "snapshot restored message" "$STDOUT" "stale modes.cfg snapshot restored"
  cmp_file "modes.cfg = local" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "state file cleared" "$STATE_DIR/state"
  file_has "dynamic modes disabled" "$STUB_STATE_DIR/dynamic.log" '^0$'
  file_has "screen wake requested" "$STUB_STATE_DIR/sleep.log" '^0$'
  file_has "xwayland restored by helper" "$STDOUT" "Xwayland #1 geometry restored to 3440x1440"
  file_has "original mode verified by helper" "$STDOUT" "original mode verified: 3440x1440@165"
  cmp_file "xwayland #1 back to local" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
}

test_precheck_failure_keeps_modes_cfg() {
  begin
  # Data-loss guard: a stale leftover snapshot without matching state must not
  # let an early failure delete/replace the user's modes.cfg.
  printf 'LEFTOVER-DO-NOT-USE\n' >"$BACKUP"
  printf 'STREAM_HEIGHT=1080\n' >"$CFG"
  run_wrapper true
  ne "fails early" "$RC" 0
  exists "modes.cfg still present" "$MODESF"
  cmp_file "modes.cfg content untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
}

test_precheck_gamescopectl_empty() {
  begin
  export STUB_NO_INFO=1
  run_wrapper true
  ne "fails when gamescopectl is unreachable" "$RC" 0
  file_has "unreachable message logged" "$LOG" "not reachable via gamescopectl"
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
}

test_target_repick_refresh() {
  begin
  export STUB_REPICK_REFRESH=164
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "accepts the gamescope refresh re-pick" "$RC" 0
  file_has "verified with actual refresh" "$LOG" "Verified target mode: 1920x1200@164"
  cmp_file "modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  eq "last DRM mode is local" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode 3440x1440@165Hz"
}

test_bypass_stream_inactive() {
  begin
  unset STUB_STREAM_ACTIVE
  export STUB_NO_INFO=1
  run_wrapper true
  eq "bypass launches the game" "$RC" 0
  file_has "bypass logged" "$LOG" "bypassing display pipeline"
  file_has "no gamescope session noted" "$LOG" "STREAM_NO_GAMESCOPE_SESSION"
  file_lacks "no detection window in Desktop Mode" "$LOG" "STREAM_WAIT_START"
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  eq "no dynamic toggles" "$(cat "$STUB_STATE_DIR/dynamic.log")" ""
}

test_bypass_ignores_lock() {
  begin
  unset STUB_STREAM_ACTIVE
  : >"$LOCKF"
  flock -n "$LOCKF" -c 'sleep 2' &
  local holder=$!
  sleep 0.5
  run_wrapper true
  eq "bypass not blocked by lock" "$RC" 0
  file_has "bypass logged" "$LOG" "bypassing display pipeline"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

test_recovery_before_bypass() {
  begin
  unset STUB_STREAM_ACTIVE
  seed_stale_state
  run_wrapper true
  eq "recovered then bypassed" "$RC" 0
  file_has "recovery completed" "$LOG" "Stale-state recovery complete"
  file_has "bypass logged" "$LOG" "bypassing display pipeline"
  cmp_file "modes.cfg = local" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "state cleared" "$STATE_DIR/state"
}

test_stream_wait_catches_race() {
  begin
  unset STUB_STREAM_ACTIVE
  printf '%s bazzite steam[1234]: Streaming started to bazzite at 192.0.2.10:39627\n' "$(date '+%b %d %H:%M:%S')" >>"$STUB_STATE_DIR/journal"
  ( sleep 1; : >"$STUB_STATE_DIR/stream-on" ) &
  printf 'STREAM_DETECT_WAIT_SECONDS=3\n' >"$CFG"
  run_wrapper true
  eq "catches the stream session (launch race)" "$RC" 0
  file_has "wait logged" "$LOG" "waiting up to 3s"
  file_has "detected after wait" "$LOG" "Steam Link streaming session detected"
  cmp_file "modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
}

test_stream_wait_expires_bypass() {
  begin
  unset STUB_STREAM_ACTIVE
  printf '%s bazzite steam[1234]: Deinitializing streaming\n' "$(date '+%b %d %H:%M:%S')" >>"$STUB_STATE_DIR/journal"
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
  run_wrapper true
  eq "bypass after the wait expires" "$RC" 0
  file_has "wait logged" "$LOG" "waiting up to 1s"
  file_has "bypass logged" "$LOG" "bypassing display pipeline"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
}

test_first_stream_no_previous_marker() {
  begin
  unset STUB_STREAM_ACTIVE
  # Spec §16: no sink, no previous Steam marker anywhere. A new session is
  # created 1s after the wrapper starts and must be caught like any other.
  printf 'STREAM_DETECT_WAIT_SECONDS=5\n' >"$CFG"
  ( sleep 1; : >"$STUB_STATE_DIR/stream-on" ) &
  run_wrapper true
  eq "first connection without marker runs the pipeline" "$RC" 0
  file_has "window opened" "$LOG" "STREAM_WAIT_START"
  file_has "sink event observed" "$LOG" "STREAM_SIGNAL_EVENT"
  file_has "session confirmed" "$LOG" "STREAM_SIGNAL_CONFIRMED"
  file_has "session detected" "$LOG" "Steam Link streaming session detected"
  file_lacks "no bypass while the session starts" "$LOG" "bypassing display pipeline"
  file_has "target mode verified" "$LOG" "Verified target mode: 3440x1440@165"
  file_has "xwayland1 confirmed" "$LOG" "XWAYLAND1_SYNC_CONFIRMED 3440x1440"
  cmp_file "modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  cmp_file "xwayland #1 back to local" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
}

test_first_stream_after_crash_leftover() {
  begin
  unset STUB_STREAM_ACTIVE
  # Spec §19: a crash left the display prepared and a stale state; the NEXT
  # connection must work as a first connection, with no marker required.
  seed_stale_state
  run_wrapper true
  eq "recovery run exit 0" "$RC" 0
  file_has "recovery completed" "$LOG" "Stale-state recovery complete"
  cmp_file "local mode restored after recovery" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "state cleared after recovery" "$STATE_DIR/state"
  ( sleep 1; : >"$STUB_STATE_DIR/stream-on" ) &
  run_wrapper true
  eq "next connection runs the pipeline" "$RC" 0
  file_has "stream detected" "$LOG" "Steam Link streaming session detected"
  file_has "xwayland1 confirmed" "$LOG" "XWAYLAND1_SYNC_CONFIRMED 3440x1440"
  cmp_file "modes.cfg restored again" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
}

test_stream_sequence() {
  local i
  for i in 1 2 3; do
    begin
    unset STUB_STREAM_ACTIVE
    use_steam_log
    steam_hint "$STEAM_STREAM_LOG" 0 'Maximum capture: 1920x1200 60.00 FPS'
    printf 'STREAM_DETECT_WAIT_SECONDS=5\n' >"$CFG"
    ( sleep 1; : >"$STUB_STATE_DIR/stream-on" ) &
    run_wrapper true
    eq "connection $i runs the pipeline" "$RC" 0
    file_has "connection $i target reached" "$LOG" "OUTPUT_TARGET_REACHED"
    file_has "connection $i xwayland1 confirmed" "$LOG" "XWAYLAND1_SYNC_CONFIRMED 1920x1200"
    file_lacks "connection $i no bypass" "$LOG" "bypassing display pipeline"
    cmp_file "connection $i modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
    cmp_file "connection $i xwayland1 local" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
    end
  done
}

test_xwayland_sync_order() {
  begin
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "exit 0" "$RC" 0
  # Ordering invariant: target reached -> sync requested -> sync confirmed -> launch.
  local a b c d
  a=$(grep -n 'OUTPUT_TARGET_REACHED' "$LOG" | head -n1 | cut -d: -f1)
  b=$(grep -n 'XWAYLAND1_SYNC_REQUESTED' "$LOG" | head -n1 | cut -d: -f1)
  c=$(grep -n 'XWAYLAND1_SYNC_CONFIRMED' "$LOG" | head -n1 | cut -d: -f1)
  d=$(grep -n 'GAME_LAUNCH' "$LOG" | head -n1 | cut -d: -f1)
  if [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] && (( a < b && b < c && c < d )); then
    say_pass "events ordered"
  else
    say_fail "events ordered (a=$a b=$b c=$c d=$d)"
  fi
  file_has "event OUTPUT_TARGET_REACHED" "$LOG" "OUTPUT_TARGET_REACHED"
  file_has "event STREAM_DETECTED" "$LOG" "STREAM_DETECTED"
  file_has "journal shows xwayland #1 update" "$STUB_STATE_DIR/journal" "Updating mode for xwayland server #1: 1920x1200@60"
}

test_xwayland_sync_failure_fails_closed() {
  begin
  export STUB_XWL_NOOP=1
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  printf 'MODE_TIMEOUT_SECONDS=1\n' >"$CFG"
  run_wrapper true
  ne "refuses to launch when Xwayland #1 does not follow" "$RC" 0
  file_has "xwayland failure logged" "$LOG" "Xwayland #1 not 1920x1200"
  file_lacks "game not started" "$LOG" "GAME_LAUNCH"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  cmp_file "modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "state cleared" "$STATE_DIR/state"
}

test_xwayland_server_missing_fails_closed() {
  begin
  export STUB_XWL1_ABSENT=1
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  printf 'MODE_TIMEOUT_SECONDS=1\n' >"$CFG"
  run_wrapper true
  ne "refuses to launch when server #1 is missing" "$RC" 0
  file_has "xwayland failure logged" "$LOG" "Xwayland #1 not 1920x1200"
  file_lacks "game not started" "$LOG" "GAME_LAUNCH"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
}

test_recovery_restores_xwayland() {
  begin
  unset STUB_STREAM_ACTIVE
  seed_stale_state
  run_wrapper true
  eq "recovered then bypassed" "$RC" 0
  file_has "recovery restored xwayland" "$LOG" "Stale-state recovery restored Xwayland #1 to 3440x1440"
  cmp_file "xwayland #1 back to local" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
  file_has "bypass logged" "$LOG" "bypassing display pipeline"
}

test_recovery_old_state_restores_xwayland() {
  begin
  unset STUB_STREAM_ACTIVE
  # A state written by an older build has no XWAYLAND_SYNCED field; #1 must
  # still be healed, per the spec's idempotent-recovery requirement.
  seed_stale_state_old_format
  run_wrapper true
  eq "recovered then bypassed" "$RC" 0
  file_has "recovery restored xwayland" "$LOG" "Stale-state recovery restored Xwayland #1 to 3440x1440"
  cmp_file "xwayland #1 back to local" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
}

test_recovery_saved_profile() {
  local i m
  local -a M=(3440x1440@165 2560x1440@144)
  for i in 0 1; do
    m=${M[$i]}
    begin
    unset STUB_STREAM_ACTIVE
    seed_stale_state "$m" "${m%@*}"
    run_wrapper true
    eq "saved profile $((i + 1)) recovered" "$RC" 0
    file_has "saved value used for verification" "$LOG" "Verified original mode: $m"
    file_has "saved xwayland restored" "$LOG" "Stale-state recovery restored Xwayland #1 to ${m%@*}"
    cmp_file "xwayland at saved value" "$STUB_STATE_DIR/xwl1_mode" "${m%@*}"
    eq "DRM back to the saved mode" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode ${m}Hz"
    absent "state cleared" "$STATE_DIR/state"
    end
  done
}

test_recovery_legacy_state_with_config() {
  begin
  unset STUB_STREAM_ACTIVE
  seed_stale_state_no_profile
  printf 'LOCAL_WIDTH=3440\nLOCAL_HEIGHT=1440\nLOCAL_REFRESH=165\n' >"$CFG"
  run_wrapper true
  eq "legacy state recovered via the legacy configuration" "$RC" 0
  file_has "recovery completed" "$LOG" "Stale-state recovery complete"
  file_has "legacy value verified" "$LOG" "Verified original mode: 3440x1440@165"
  file_has "legacy xwayland restored" "$LOG" "Stale-state recovery restored Xwayland #1 to 3440x1440"
  cmp_file "xwayland at the legacy value" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
  absent "state cleared" "$STATE_DIR/state"
}

test_recovery_legacy_state_no_config() {
  begin
  unset STUB_STREAM_ACTIVE
  seed_stale_state_no_profile
  run_wrapper true
  eq "legacy recovery completes best-effort" "$RC" 0
  file_has "recovery completed" "$LOG" "Stale-state recovery complete"
  file_has "mode skip warned" "$LOG" "no original mode recorded"
  file_has "xwayland skip warned" "$LOG" "no original Xwayland geometry recorded"
  cmp_file "modes.cfg restored anyway" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "state cleared" "$STATE_DIR/state"
}

test_hint_parse() {
  begin
  use_steam_log
  local out
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  out=$(hook_num get_latest_stream_capture_hint)
  eq "hint 1920x1200@60 parsed" "$out" "1920 1200 60"
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1280x800 89.00 FPS'
  out=$(hook_num get_latest_stream_capture_hint)
  eq "hint 1280x800@89 parsed" "$out" "1280 800 89"
  end
}

test_hint_invalid() {
  begin
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: invalid'
  eq "unparsable hint yields nothing" "$(hook_num get_latest_stream_capture_hint)" ""
  end
}

test_hint_stale() {
  begin
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 60 'Maximum capture: 1920x1200 60.00 FPS'
  eq "stale hint ignored" "$(hook_num get_latest_stream_capture_hint)" ""
  end
}

test_resolver_exact() {
  begin
  export STUB_MODE_LIST="1920x1200@60 3440x1440@165"
  eq "exact host mode preferred" "$(hook_num resolve_target_mode 1920 1200 60)" "1920 1200 60"
  end
}

test_resolver_aspect() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60 1920x1080@60"
  eq "aspect match preferred over 16:9" "$(hook_num resolve_target_mode 1280 800 89)" "1920 1200 60"
  end
}

test_resolver_client_169() {
  begin
  export STUB_MODE_LIST="1920x1200@60 1920x1080@60"
  eq "client 16:9 keeps its own geometry" "$(hook_num resolve_target_mode 1920 1080 60)" "1920 1080 60"
  end
}

test_resolver_client_fps() {
  begin
  export STUB_MODE_LIST="1280x800@60 1280x800@90"
  eq "refresh sufficient for client FPS" "$(hook_num resolve_target_mode 1280 800 89)" "1280 800 90"
  end
}

test_resolver_no_compatible() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  eq "no compatible mode yields nothing" "$(hook_num resolve_target_mode 2560 1440 60)" ""
  end
}

test_no_hint_host_safe_fallback() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  run_wrapper true
  eq "runs on the host-safe fallback" "$RC" 0
  file_has "hint unavailable" "$LOG" "CLIENT_HINT unavailable"
  file_has "host fallback source" "$LOG" "TARGET_MODE_RESOLVED 3440x1440@165 source=host_original"
  file_has "host fallback target reached" "$LOG" "OUTPUT_TARGET_REACHED 3440x1440@165"
  file_lacks "configured client fallback not used" "$LOG" "TARGET_MODE_RESOLVED 1920x1200@60"
  file_has "original verified" "$LOG" "Verified original mode: 3440x1440@165"
  end
  begin
  set_host HDMI-A-1 "2560x1440@144" "2560x1440@144 1920x1080@60"
  run_wrapper true
  eq "host B runs on its own original mode" "$RC" 0
  file_has "host B fallback is its own mode" "$LOG" "TARGET_MODE_RESOLVED 2560x1440@144 source=host_original"
  eq "host B DRM restored" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode 2560x1440@144Hz"
  end
}

test_host_agnostic_matrix() {
  local i
  local -a C=(DP-3 HDMI-A-1 DP-1 HDMI-1)
  local -a H=("3440x1440@165" "2560x1440@144" "3840x2160@120" "1920x1080@60")
  local -a L=("3440x1440@165 1920x1200@60" "2560x1440@144 1920x1080@60" \
              "3840x2160@120 1920x1080@60 1920x1200@60" "1920x1080@60")
  local -a Q=('Maximum capture: 1920x1200 60.00 FPS' 'Maximum capture: 1920x1080 60.00 FPS' \
              'Maximum capture: 1280x800 60.00 FPS' 'Maximum capture: 1920x1080 60.00 FPS')
  local -a T=(1920x1200@60 1920x1080@60 1920x1200@60 1920x1080@60)
  for i in 0 1 2 3; do
    begin
    set_host "${C[$i]}" "${H[$i]}" "${L[$i]}"
    use_steam_log
    steam_hint "$STEAM_STREAM_LOG" 1 "${Q[$i]}"
    run_wrapper true
    eq "host $((i + 1)) runs" "$RC" 0
    file_has "host $((i + 1)) profile detected" "$LOG" "HOST_PROFILE_DETECTED connector=${C[$i]} mode=${H[$i]}"
    file_has "host $((i + 1)) target reached" "$LOG" "OUTPUT_TARGET_REACHED ${T[$i]}"
    eq "host $((i + 1)) original DRM restored" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode ${H[$i]}Hz"
    cmp_file "host $((i + 1)) xwayland restored" "$STUB_STATE_DIR/xwl1_mode" "${H[$i]%@*}"
    cmp_file "host $((i + 1)) modes.cfg restored" "$MODESF" "StubMake StubModel:${H[$i]} 0"
    end
  done
}

test_connector_dynamic() {
  local out c
  begin
  set_host HDMI-A-1 "2560x1440@144" "2560x1440@144 1920x1080@60"
  unset STUB_MODE_LIST
  mkdir -p "$SANDBOX/drmsys/card1-HDMI-A-1"
  printf '2560x1440\n1920x1080\n' >"$SANDBOX/drmsys/card1-HDMI-A-1/modes"
  export DRM_MODES_GLOB="$SANDBOX/drmsys/card*-HDMI-A-1/modes"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1080 60.00 FPS'
  run_wrapper true
  eq "auto follows the gamescope connector" "$RC" 0
  file_has "profile uses the runtime connector" "$LOG" "HOST_PROFILE_DETECTED connector=HDMI-A-1 mode=2560x1440@144"
  file_has "kernel fallback queries the runtime connector" "$LOG" "checking kernel ModeDB for HDMI-A-1"
  file_has "original restored from the runtime connector" "$LOG" "Verified original mode: 2560x1440@144"
  eq "runtime connector mode restored" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode 2560x1440@144Hz"
  for c in DP-3 HDMI-A-1 DP-1; do
    out=$(env ACTIVE_CONNECTOR="$c" bash -c 'LIB_ROOT="$1"; source "$LIB_ROOT/core/bootstrap.sh"; drm_modes_default_glob' _ "$LIB")
    eq "default glob uses $c" "$out" "/sys/class/drm/card*-$c/modes"
  done
  end
}

test_refresh_variants() {
  local r
  for r in 60 120 144 165 240; do
    begin
    set_host DP-2 "2560x1440@$r" "2560x1440@$r 1920x1080@60"
    use_steam_log
    steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1080 60.00 FPS'
    run_wrapper true
    eq "host at ${r}Hz runs" "$RC" 0
    file_has "host captured at ${r}Hz" "$LOG" "HOST_PROFILE_DETECTED connector=DP-2 mode=2560x1440@$r"
    file_has "original verified at ${r}Hz" "$LOG" "Verified original mode: 2560x1440@$r"
    eq "restore uses the detected ${r}Hz" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode 2560x1440@${r}Hz"
    end
  done
}

test_host_profile_fail_closed() {
  begin
  : >"$STUB_STATE_DIR/journal"
  run_wrapper true
  ne "fails closed without the original host mode" "$RC" 0
  file_has "capture failure logged" "$LOG" "unable to determine the current host mode"
  file_lacks "game not started" "$LOG" "GAME_LAUNCH"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  eq "no dynamic toggles" "$(cat "$STUB_STATE_DIR/dynamic.log")" ""
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
}

test_client_mode_applied() {
  begin
  use_steam_log
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60 1280x800@90"
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1280x800 89.00 FPS'
  run_wrapper true
  eq "runs with the client target" "$RC" 0
  file_has "client hint logged" "$LOG" "CLIENT_HINT 1280x800@89"
  file_has "target resolved from hint" "$LOG" "TARGET_MODE_RESOLVED 1280x800@90 source=steam_capture_hint"
  file_has "output at target" "$LOG" "OUTPUT_TARGET_REACHED 1280x800@90"
  file_has "modes.cfg got the target" "$LOG" "Configured saved mode: StubMake StubModel:1280x800@90"
  file_has "xwayland1 requested at target" "$LOG" "XWAYLAND1_SYNC_REQUESTED 1/1280/800/0"
  file_has "xwayland1 confirmed at target" "$LOG" "XWAYLAND1_SYNC_CONFIRMED 1280x800"
  file_has "journal xwayland #1 at target" "$STUB_STATE_DIR/journal" "xwayland server #1: 1280x800"
  cmp_file "modes.cfg restored to local" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  cmp_file "xwayland #1 restored to local" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
  end
}

test_fixed_mode_ignores_hint() {
  begin
  use_steam_log
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60 1920x1080@60"
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1080 60.00 FPS'
  printf 'STREAM_MODE=fixed\n' >"$CFG"
  run_wrapper true
  eq "fixed mode runs" "$RC" 0
  file_has "fixed target" "$LOG" "TARGET_MODE_RESOLVED 1920x1200@60 source=fixed"
  file_lacks "hint not read in fixed mode" "$LOG" "CLIENT_HINT"
  file_has "fixed geometry reached" "$LOG" "OUTPUT_TARGET_REACHED 1920x1200@60"
  end
}

test_no_compatible_mode_fails_closed() {
  begin
  use_steam_log
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 2560x1440 60.00 FPS'
  run_wrapper true
  ne "fails closed without a compatible mode" "$RC" 0
  file_has "no compatible mode logged" "$LOG" "TARGET_MODE_NO_COMPATIBLE_HOST_MODE"
  file_lacks "game not started" "$LOG" "GAME_LAUNCH"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  end
}

test_policy_always_allows_fallback() {
  begin
  use_steam_log
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 2560x1440 60.00 FPS'
  printf "STREAM_NO_COMPATIBLE_FALLBACK='always'\n" >"$CFG"
  run_wrapper true
  eq "always policy uses the configured fallback" "$RC" 0
  file_has "no compatible mode logged" "$LOG" "TARGET_MODE_NO_COMPATIBLE_HOST_MODE"
  file_has "fallback target" "$LOG" "TARGET_MODE_RESOLVED 1920x1200@60 source=fallback"
  file_has "output at fallback" "$LOG" "OUTPUT_TARGET_REACHED 1920x1200@60"
  end
}

test_client_sequence_recomputed() {
  local i
  local -a M=("3440x1440@165 1920x1200@60" "3440x1440@165 1920x1200@60 1280x800@90" "3440x1440@165 1920x1200@60 1920x1080@60")
  local -a H=('Maximum capture: 1920x1200 60.00 FPS' 'Maximum capture: 1280x800 89.00 FPS' 'Maximum capture: 1920x1080 60.00 FPS')
  local -a T=('1920x1200@60' '1280x800@90' '1920x1080@60')
  for i in 0 1 2; do
    begin
    use_steam_log
    export STUB_MODE_LIST="${M[$i]}"
    steam_hint "$STEAM_STREAM_LOG" 1 "${H[$i]}"
    run_wrapper true
    eq "session $((i + 1)) runs" "$RC" 0
    file_has "session $((i + 1)) target ${T[$i]}" "$LOG" "TARGET_MODE_RESOLVED ${T[$i]} source=steam_capture_hint"
    file_has "session $((i + 1)) output ${T[$i]}" "$LOG" "OUTPUT_TARGET_REACHED ${T[$i]}"
    file_has "session $((i + 1)) no stale previous target" "$LOG" "CLIENT_HINT"
    cmp_file "session $((i + 1)) local restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
    cmp_file "session $((i + 1)) xwayland local" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
    end
  done
}

test_first_connection_hint() {
  begin
  unset STUB_STREAM_ACTIVE
  use_steam_log
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  printf 'STREAM_DETECT_WAIT_SECONDS=5\n' >"$CFG"
  steam_hint "$STEAM_STREAM_LOG" 0 'Maximum capture: 1920x1200 60.00 FPS'
  ( sleep 1; : >"$STUB_STATE_DIR/stream-on" ) &
  run_wrapper true
  eq "first connection with hint runs the pipeline" "$RC" 0
  file_has "session confirmed" "$LOG" "STREAM_SIGNAL_CONFIRMED"
  file_has "client hint" "$LOG" "CLIENT_HINT 1920x1200@60"
  file_has "target resolved from hint" "$LOG" "TARGET_MODE_RESOLVED 1920x1200@60 source=steam_capture_hint"
  file_has "xwayland1 confirmed" "$LOG" "XWAYLAND1_SYNC_CONFIRMED 1920x1200"
  file_has "game launch" "$LOG" "GAME_LAUNCH"
  cmp_file "modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  end
}

test_geometry_no_crash_regression() {
  begin
  use_steam_log
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60 1920x1080@60"
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1080 60.00 FPS'
  run_wrapper true
  eq "runs" "$RC" 0
  file_has "output is the client geometry" "$LOG" "OUTPUT_TARGET_REACHED 1920x1080@60"
  file_has "xwayland #1 confirmed client geometry" "$LOG" "XWAYLAND1_SYNC_CONFIRMED 1920x1080"
  eq "xwayland #1 first updated to the client geometry" \
    "$(grep -m1 'xwayland server #1' "$STUB_STATE_DIR/journal")" \
    "wlserver: Updating mode for xwayland server #1: 1920x1080@60"
  cmp_file "xwayland #1 restored to local" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
  cmp_file "modes.cfg restored to local" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  end
}


test_cli_parser_values() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60 2560x1440@120"
  run_wrapper --mode 2560x1440 true
  eq "cli resolution runs" "$RC" 0
  file_has "MODE_SOURCE=cli" "$LOG" "MODE_SOURCE=cli"
  file_has "CLI_MODE is the requested geometry" "$LOG" "CLI_MODE=2560x1440"
  file_has "target refresh from the resolver" "$LOG" "TARGET_MODE=2560x1440@120"
  file_has "cli source" "$LOG" "source=cli"
  file_lacks "client hint not read with cli" "$LOG" "CLIENT_HINT"
  end
}

test_cli_resolution_only() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60 1920x1200@90 1920x1200@120"
  run_wrapper --mode 1920x1200 true
  eq "resolution-only runs" "$RC" 0
  file_has "CLI_MODE without refresh" "$LOG" "CLI_MODE=1920x1200"
  file_has "geometry fixed, refresh from the resolver" "$LOG" "TARGET_MODE=1920x1200@120"
  file_lacks "refresh not the fallback 60 implicitly" "$LOG" "TARGET_MODE=1920x1200@60"
  end
}

test_cli_mode_equal() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  run_wrapper --mode=1920x1200 true
  eq "--mode=WxH accepted" "$RC" 0
  file_has "CLI_MODE from --mode=" "$LOG" "CLI_MODE=1920x1200"
  file_has "target from --mode=" "$LOG" "TARGET_MODE=1920x1200@60"
  end
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  rm -f "$LOG"
  run_wrapper --mode=1920x1200@60 true
  ne "--mode=WxH@FPS rejected" "$RC" 0
  file_has "invalid logged" "$LOG" "invalid --mode value"
  end
}

test_cli_invalid_at_fps() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  printf 'PHASE=STREAMING\n' >"$STATE_DIR/state"
  run_wrapper --mode 1920x1200@60 true
  ne "WxH@FPS rejected" "$RC" 0
  file_has "invalid value logged" "$LOG" "invalid --mode value: 1920x1200@60"
  file_lacks "game not started" "$LOG" "GAME_LAUNCH"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  eq "no dynamic toggles" "$(cat "$STUB_STATE_DIR/dynamic.log")" ""
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  file_has "state untouched" "$STATE_DIR/state" "PHASE=STREAMING"
  end
}

test_cli_unavailable_resolution() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  run_wrapper --mode 2560x1440 true
  ne "fails closed when the fixed resolution is unavailable" "$RC" 0
  file_has "unavailable logged" "$LOG" "TARGET_MODE_UNAVAILABLE 2560x1440"
  file_lacks "game not started" "$LOG" "GAME_LAUNCH"
  end
}

test_cli_invalid_values() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  local v
  for v in '1920' 'x1200' '1920x' '1920x1200@' '@60' '1920x1200@abc' '-1920x1200' '0x1200' '1920x0' \
           '1920x1200@60' '1920x1200@90' '2560x1440@120' '1280x800@75' '1920x1200@0' '1920x1200@-60' '1920x1200@60foo'; do
    rm -f "$LOG"
    run_wrapper --mode "$v" true
    ne "rejects --mode '$v'" "$RC" 0
  done
  file_has "invalid value logged" "$LOG" "invalid --mode value"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  eq "no dynamic toggles" "$(cat "$STUB_STATE_DIR/dynamic.log")" ""
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  end
}

test_cli_duplicate_and_unknown() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  rm -f "$LOG"
  run_wrapper --mode 1920x1200 --mode 1280x800 true
  ne "duplicate --mode rejected" "$RC" 0
  file_has "duplicate logged" "$LOG" "duplicate --mode option"
  rm -f "$LOG"
  run_wrapper --foo bar true
  ne "unknown wrapper option rejected" "$RC" 0
  file_has "unknown logged" "$LOG" "unknown wrapper option: --foo"
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  end
}

test_cli_help() {
  begin
  run_wrapper --help
  eq "help exits 0" "$RC" 0
  file_has "usage printed" "$STDERR" "Usage:"
  file_has "mode documented" "$STDERR" "--mode WxH"
  file_lacks "no @FPS in help" "$STDERR" "@FPS"
  absent "no state written" "$STATE_DIR/state"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  end
}

test_cli_argv_preserved() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  run_wrapper --mode 1920x1200 bash -c 'printf "%s\n" "$@" > "$0"' "$SANDBOX/game_args" --arg1 foo --arg2 bar
  eq "runs" "$RC" 0
  cmp_file "game argv preserved verbatim" "$SANDBOX/game_args" $'--arg1\nfoo\n--arg2\nbar'
  if grep -q 'GAME_LAUNCH' "$LOG" && ! grep -q -- '--mode' <<<"$(grep 'GAME_LAUNCH' "$LOG" | head -n1)"; then
    say_pass "no --mode forwarded to the game"
  else
    say_fail "no --mode forwarded to the game"
  fi
  end
}

test_cli_precedence() {
  begin
  use_steam_log
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  printf 'STREAM_MODE=fixed\n' >"$CFG"
  run_wrapper --mode auto true
  eq "cli auto wins over config fixed" "$RC" 0
  file_has "hint used" "$LOG" "source=steam_capture_hint"
  file_lacks "config fixed not used" "$LOG" "source=fixed"
  end
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1080@60"
  run_wrapper --mode 1920x1080 true
  eq "cli geometry wins over config auto" "$RC" 0
  file_has "cli source" "$LOG" "source=cli"
  file_has "cli target" "$LOG" "TARGET_MODE=1920x1080@60"
  end
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  printf 'STREAM_MODE=fixed\n' >"$CFG"
  run_wrapper true
  eq "config fixed with no cli" "$RC" 0
  file_has "config source" "$LOG" "source=fixed"
  file_has "mode source config" "$LOG" "MODE_SOURCE=config"
  end
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  run_wrapper true
  eq "auto default with no cli" "$RC" 0
  file_has "host original source" "$LOG" "source=host_original"
  file_has "mode source host original" "$LOG" "MODE_SOURCE=host_original"
  end
}

test_cli_fixed_across_clients() {
  local i
  local -a H=('Maximum capture: 1920x1200 60.00 FPS' 'Maximum capture: 1280x800 89.00 FPS' 'Maximum capture: 1920x1080 60.00 FPS')
  for i in 0 1 2; do
    begin
    use_steam_log
    export STUB_MODE_LIST="3440x1440@165 1920x1200@60 1920x1080@60 1280x800@90"
    steam_hint "$STEAM_STREAM_LOG" 1 "${H[$i]}"
    run_wrapper --mode 1920x1200 true
    eq "client $((i + 1)) runs" "$RC" 0
    file_has "client $((i + 1)) fixed geometry" "$LOG" "TARGET_MODE=1920x1200@60"
    file_has "client $((i + 1)) cli source" "$LOG" "source=cli"
    file_lacks "client $((i + 1)) hint ignored" "$LOG" "source=steam_capture_hint"
    cmp_file "client $((i + 1)) local restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
    end
  done
}

test_fixed_across_hosts() {
  local i
  local -a C=(HDMI-A-1 DP-1)
  local -a H=("2560x1440@144" "3840x2160@120")
  local -a L=("2560x1440@144 1920x1080@60" "3840x2160@120 1920x1080@60 1920x1200@60")
  for i in 0 1; do
    begin
    set_host "${C[$i]}" "${H[$i]}" "${L[$i]}"
    use_steam_log
    steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1280x800 60.00 FPS'
    printf 'STREAM_MODE=fixed\nSTREAM_WIDTH=1920\nSTREAM_HEIGHT=1080\nSTREAM_REFRESH=60\nSTREAM_ASPECT="16:9"\n' >"$CFG"
    run_wrapper true
    eq "fixed on host $((i + 1)) runs" "$RC" 0
    file_has "fixed target on host $((i + 1))" "$LOG" "TARGET_MODE_RESOLVED 1920x1080@60 source=fixed"
    file_lacks "hint not read in fixed mode on host $((i + 1))" "$LOG" "CLIENT_HINT"
    eq "host $((i + 1)) original restored" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode ${H[$i]}Hz"
    cmp_file "host $((i + 1)) xwayland restored" "$STUB_STATE_DIR/xwl1_mode" "${H[$i]%@*}"
    end
  done
}

test_cli_across_hosts() {
  local i
  local -a C=(DP-3 HDMI-A-1)
  local -a H=("3440x1440@165" "2560x1440@144")
  local -a L=("3440x1440@165 1920x1080@60" "2560x1440@144 1920x1080@60")
  for i in 0 1; do
    begin
    set_host "${C[$i]}" "${H[$i]}" "${L[$i]}"
    run_wrapper --mode 1920x1080 true
    eq "cli on host $((i + 1)) runs" "$RC" 0
    file_has "cli target on host $((i + 1))" "$LOG" "TARGET_MODE=1920x1080@60"
    file_has "cli source on host $((i + 1))" "$LOG" "source=cli"
    eq "host $((i + 1)) original restored after cli" "$(grep 'selecting mode' "$STUB_STATE_DIR/journal" | tail -n 1)" "drm: selecting mode ${H[$i]}Hz"
    end
  done
}

test_cli_first_connection() {
  begin
  unset STUB_STREAM_ACTIVE
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  printf 'STREAM_DETECT_WAIT_SECONDS=5\n' >"$CFG"
  ( sleep 1; : >"$STUB_STATE_DIR/stream-on" ) &
  run_wrapper --mode 1920x1200 true
  eq "first connection with cli runs" "$RC" 0
  file_has "session confirmed" "$LOG" "STREAM_SIGNAL_CONFIRMED"
  file_has "cli target" "$LOG" "TARGET_MODE=1920x1200@60"
  file_has "xwayland confirmed" "$LOG" "XWAYLAND1_SYNC_CONFIRMED 1920x1200"
  file_has "game launch" "$LOG" "GAME_LAUNCH"
  end
}

test_cli_recovery() {
  begin
  seed_stale_state
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  run_wrapper --mode 1920x1200 true
  eq "recovered and ran with cli" "$RC" 0
  file_has "recovery completed" "$LOG" "Stale-state recovery complete"
  file_has "cli target after recovery" "$LOG" "TARGET_MODE=1920x1200@60"
  cmp_file "modes.cfg local after run" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  cmp_file "xwayland local after run" "$STUB_STATE_DIR/xwl1_mode" '3440x1440'
  end
}

test_cli_bypass_local() {
  begin
  unset STUB_STREAM_ACTIVE
  export STUB_NO_INFO=1
  run_wrapper --mode 1920x1200 true
  eq "bypass launches the game" "$RC" 0
  file_has "bypass logged" "$LOG" "bypassing display pipeline"
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  eq "no dynamic toggles" "$(cat "$STUB_STATE_DIR/dynamic.log")" ""
  end
}

test_cli_streaming_geometry() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1080@60"
  run_wrapper --mode 1920x1080 true
  eq "runs" "$RC" 0
  file_has "output target" "$LOG" "OUTPUT_TARGET_REACHED 1920x1080@60"
  file_has "xwayland requested" "$LOG" "XWAYLAND1_SYNC_REQUESTED 1/1920/1080/0"
  file_has "xwayland confirmed" "$LOG" "XWAYLAND1_SYNC_CONFIRMED 1920x1080"
  eq "xwayland #1 first update is the target" \
    "$(grep -m1 'xwayland server #1' "$STUB_STATE_DIR/journal")" \
    "wlserver: Updating mode for xwayland server #1: 1920x1080@60"
  cmp_file "local restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  end
}

test_cli_state_persisted() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  set -m
  bash "$WRAPPER" --mode 1920x1200 sleep 30 >"$STDOUT" 2>"$STDERR" &
  local wp=$!
  set +m
  local i=0
  while (( i < 150 )); do
    if [[ -f "$LOG" ]] && grep -q "Game PID:" "$LOG"; then break; fi
    sleep 0.1; i=$((i + 1))
  done
  file_has "state TARGET_WIDTH" "$STATE_DIR/state" "TARGET_WIDTH=1920"
  file_has "state TARGET_SOURCE" "$STATE_DIR/state" "TARGET_SOURCE=cli"
  file_has "state TARGET_MODE_SPEC" "$STATE_DIR/state" "TARGET_MODE_SPEC=1920x1200"
  file_has "state ORIGINAL_CONNECTOR" "$STATE_DIR/state" "ORIGINAL_CONNECTOR=DP-3"
  file_has "state ORIGINAL_MODE" "$STATE_DIR/state" "ORIGINAL_MODE=3440x1440@165"
  file_has "state ORIGINAL_XWAYLAND_MODE" "$STATE_DIR/state" "ORIGINAL_XWAYLAND_MODE=3440x1440"
  file_has "state DISPLAY_DESCRIPTION" "$STATE_DIR/state" "DISPLAY_DESCRIPTION=StubMake StubModel"
  kill -TERM "$wp" 2>/dev/null || true
  wait "$wp" 2>/dev/null || true
  end
}

test_rename_repo_namespace_clean() {
  local out
  # Lines explicitly marked as an intentional historical reference (the README
  # migration note) are allowed; anything else is an accidental leftover.
  out=$(grep -rnE --exclude-dir=.git "$LEG_PROJ|$LEG_BRAND" "$PKG_DIR" 2>/dev/null \
        | grep -v 'intentional-legacy' || true)
  eq "no legacy namespace anywhere in the repo" "$out" ""
}

test_rename_files_and_identity() {
  begin
  exists "new wrapper source" "$PKG_DIR/bin/steam-link-display-adapter.sh"
  absent "old wrapper source gone" "$PKG_DIR/$LEG_BRAND-wrapper.sh"
  exists "library loader" "$PKG_DIR/lib/core/bootstrap.sh"
  absent "no monolithic hook" "$PKG_DIR/lib/steam-link-display-adapter-hook.sh"
  exists "new restore source" "$PKG_DIR/bin/steam-link-display-adapter-restore.sh"
  exists "new verify source" "$PKG_DIR/bin/steam-link-display-adapter-verify-environment.sh"
  exists "new conf example" "$PKG_DIR/config/steam-link-display-adapter.conf.example"
  absent "old conf example gone" "$PKG_DIR/$LEG_BRAND.conf.example"
  run_wrapper --help
  file_has "help shows new executable" "$STDERR" 'steam-link-display-adapter \[OPTIONS\] %command%'
  file_lacks "help has no old executable" "$STDERR" "$LEG_PROJ"
  end
}

test_rename_install_paths() {
  begin
  bash "$PKG_DIR/install.sh" >"$STDOUT" 2>"$STDERR"
  RC=$?
  eq "installer runs" "$RC" 0
  exists "new executable installed" "$HOME/.local/bin/steam-link-display-adapter"
  absent "old executable not installed" "$HOME/.local/bin/$LEG_PROJ"
  exists "library tree installed" "$HOME/.local/lib/steam-link-display-adapter/core/bootstrap.sh"
  exists "library module installed" "$HOME/.local/lib/steam-link-display-adapter/display/mode.sh"
  absent "no single-file hook installed" "$HOME/.local/lib/steam-link-display-adapter/steam-link-display-adapter-hook.sh"
  absent "hook not a public command" "$HOME/.local/bin/steam-link-display-adapter-hook.sh"
  absent "old hook not installed" "$HOME/.local/bin/$LEG_BRAND-hook.sh"
  exists "new verify installed" "$HOME/.local/bin/steam-link-display-adapter-verify-environment"
  exists "new restore installed" "$HOME/.local/bin/steam-link-display-adapter-restore"
  exists "new config installed" "$XDG_CONFIG_HOME/steam-link-display-adapter/config"
  absent "no legacy config dir" "$XDG_CONFIG_HOME/$LEG_BRAND"
  file_has "installer prints new launch option" "$STDOUT" "steam-link-display-adapter %command%"
  file_lacks "installer has no old launch option" "$STDOUT" "$LEG_PROJ"
  end
}

test_rename_runtime_namespace() {
  begin
  run_wrapper true
  eq "wrapper still runs" "$RC" 0
  exists "new log path used" "$LOG"
  file_lacks "log has no old prefix" "$LOG" "$LEG_PROJ"
  absent "no legacy state dir" "$XDG_STATE_HOME/$LEG_BRAND"
  absent "no legacy config dir" "$XDG_CONFIG_HOME/$LEG_BRAND"
  end
}

test_project_structure() {
  # Layout regression guard (spec §13): the invariants that matter, not every
  # internal file name.
  local d e l
  begin
  exists "root readme" "$PKG_DIR/README.md"
  exists "root installer" "$PKG_DIR/install.sh"
  exists "test runner" "$PKG_DIR/tests/run-tests.sh"
  exists "config template" "$PKG_DIR/config/steam-link-display-adapter.conf.example"
  exists "technical doc" "$PKG_DIR/docs/technical/DOCUMENTAZIONE-TECNICA.md"
  for d in analysis; do
    exists "docs area $d" "$PKG_DIR/docs/$d"
  done
  # entrypoints
  for e in steam-link-display-adapter.sh steam-link-display-adapter-restore.sh \
           steam-link-display-adapter-verify-environment.sh; do
    exists "entrypoint $e" "$PKG_DIR/bin/$e"
    if [[ -x "$PKG_DIR/bin/$e" ]]; then
      say_pass "entrypoint executable $e"
    else
      say_fail "entrypoint executable $e"
    fi
  done
  # library: one loader plus one directory per responsibility
  exists "library loader" "$PKG_DIR/lib/core/bootstrap.sh"
  exists "host profile module" "$PKG_DIR/lib/display/profile.sh"
  for d in core detection display logging resolution state system xwayland; do
    exists "library area $d" "$PKG_DIR/lib/$d"
  done
  # library files are loaded with source: never executable
  for l in core/bootstrap.sh core/workflow.sh logging/logging.sh detection/steam-link.sh \
           display/connector.sh display/mode.sh display/profile.sh resolution/resolver.sh \
           xwayland/mode.sh state/state.sh; do
    if [[ -x "$PKG_DIR/lib/$l" ]]; then
      say_fail "library not executable ${l##*/}"
    else
      say_pass "library not executable ${l##*/}"
    fi
  done
  # analyses kept
  local a
  for a in ANALISI-FUNZIONALE.md ANALISI-FUNZIONALE-PRIMA-CONNESSIONE.md \
           ANALISI-RISOLUZIONE-DINAMICA.md ANALISI-XWAYLAND-1.md \
           ANALISI-CLI-MODE.md ANALISI-RIMOZIONE-FPS-CLI.md \
           ANALISI-HOST-DISPLAY-AGNOSTIC.md; do
    exists "analysis $a" "$PKG_DIR/docs/analysis/$a"
  done
  # no duplicate / stale copies
  absent "no root wrapper copy" "$PKG_DIR/steam-link-display-adapter.sh"
  absent "no monolithic hook in lib" "$PKG_DIR/lib/steam-link-display-adapter-hook.sh"
  absent "no stale public hook in bin" "$PKG_DIR/bin/steam-link-display-adapter-hook.sh"
  absent "no root technical doc" "$PKG_DIR/DOCUMENTAZIONE-TECNICA.md"
  absent "no root analysis" "$PKG_DIR/ANALISI-FUNZIONALE.md"
  end
}


TESTS=(
  happy_path
  config_invalid
  config_invalid_aspect
  precheck_mode_missing
  precheck_connector_mismatch
  precheck_kernel_fallback_ok
  precheck_kernel_fallback_missing
  switch_timeout
  switch_command_failure
  sleep_failure
  exit_code_preserved
  lock_contention
  stale_state_recovery
  signals
  restore_helper
  precheck_failure_keeps_modes_cfg
  precheck_gamescopectl_empty
  target_repick_refresh
  bypass_stream_inactive
  bypass_ignores_lock
  recovery_before_bypass
  stream_wait_catches_race
  stream_wait_expires_bypass
  first_stream_no_previous_marker
  first_stream_after_crash_leftover
  stream_sequence
  xwayland_sync_order
  xwayland_sync_failure_fails_closed
  xwayland_server_missing_fails_closed
  recovery_restores_xwayland
  recovery_old_state_restores_xwayland
  recovery_saved_profile
  recovery_legacy_state_with_config
  recovery_legacy_state_no_config
  hint_parse
  hint_invalid
  hint_stale
  resolver_exact
  resolver_aspect
  resolver_client_169
  resolver_client_fps
  resolver_no_compatible
  no_hint_host_safe_fallback
  host_agnostic_matrix
  connector_dynamic
  refresh_variants
  host_profile_fail_closed
  client_mode_applied
  fixed_mode_ignores_hint
  no_compatible_mode_fails_closed
  policy_always_allows_fallback
  client_sequence_recomputed
  first_connection_hint
  geometry_no_crash_regression
  cli_parser_values
  cli_resolution_only
  cli_mode_equal
  cli_invalid_at_fps
  cli_unavailable_resolution
  cli_invalid_values
  cli_duplicate_and_unknown
  cli_help
  cli_argv_preserved
  cli_precedence
  cli_fixed_across_clients
  fixed_across_hosts
  cli_across_hosts
  cli_first_connection
  cli_recovery
  cli_bypass_local
  cli_streaming_geometry
  cli_state_persisted
  rename_repo_namespace_clean
  rename_files_and_identity
  rename_install_paths
  rename_runtime_namespace
  project_structure
)

echo "steam-link-display-adapter wrapper test suite"
echo "package: $PKG_DIR"
echo
for t in "${TESTS[@]}"; do
  if [[ -n "$FILTER" && "$t" != *"$FILTER"* ]]; then continue; fi
  "test_$t"
done
echo
echo "== PASS=$PASS FAIL=$FAIL =="
if (( FAIL > 0 )); then
  printf 'failed:\n'
  printf '  %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0

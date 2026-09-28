#!/usr/bin/env bash
# run-tests.sh - hardware-free test suite for the steamlink-display wrapper.
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
WRAPPER="$PKG_DIR/steamlink-display-wrapper.sh"
RESTORE="$PKG_DIR/steamlink-display-restore.sh"
STUBS="$TESTS_DIR/stubs"
BASE_PATH="$PATH"
FILTER=${1:-}

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
  export STUB_STREAM_ACTIVE=1
  mkdir -p "$HOME/.config/gamescope" "$XDG_CONFIG_HOME/steamlink-display" "$XDG_STATE_HOME/steamlink-display" "$STUB_STATE_DIR"
  STATE_DIR="$XDG_STATE_HOME/steamlink-display"
  BACKUP="$STATE_DIR/modes.cfg.backup"
  LOCKF="$STATE_DIR/lock"
  MODESF="$HOME/.config/gamescope/modes.cfg"
  CFG="$XDG_CONFIG_HOME/steamlink-display/config"
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
  printf 'StubMake StubModel:1920x1200@60\n' >"$MODESF"
  printf '1920x1200@60\n' >"$STUB_STATE_DIR/mode"
  printf '1920x1200\n' >"$STUB_STATE_DIR/xwl1_mode"
  printf 'drm: selecting mode 1920x1200@60Hz\n' >>"$STUB_STATE_DIR/journal"
  printf 'StubMake StubModel:3440x1440@165 0\n' >"$BACKUP"
  {
    printf 'VERSION=1\n'
    printf 'PHASE=STREAMING\n'
    printf 'MODES_BACKUP=%s\n' "$BACKUP"
    printf 'MODES_EXISTED=1\n'
    printf 'SCREEN_SLEEP_REQUESTED=1\n'
    printf 'XWAYLAND_SYNCED=1\n'
  } >"$STATE_DIR/state"
}

# State written by a build that predates the XWAYLAND_SYNCED field.
seed_stale_state_old_format() {
  seed_stale_state
  grep -v '^XWAYLAND_SYNCED=' "$STATE_DIR/state" >"$STATE_DIR/state.tmp"
  mv "$STATE_DIR/state.tmp" "$STATE_DIR/state"
}

test_happy_path() {
  begin
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
  file_has "local mode re-verified" "$LOG" "Verified local mode: 3440x1440@165"
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
  ne "refuses 1920x1080" "$RC" 0
  file_has "resolution error logged" "$LOG" "stream resolution must be 1920x1200"
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  file_lacks "game not started" "$LOG" "Launching game:"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
}

test_config_invalid_aspect() {
  begin
  printf "STREAM_ASPECT='21:9'\n" >"$CFG"
  run_wrapper true
  ne "refuses 21:9" "$RC" 0
  file_has "aspect error logged" "$LOG" "stream aspect must be 16:10"
}

test_precheck_mode_missing() {
  begin
  export STUB_MODE_LIST="3440x1440@165"
  run_wrapper true
  ne "fails when target not advertised" "$RC" 0
  file_has "mode error logged" "$LOG" "does not currently advertise 1920x1200@60"
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
}

test_precheck_connector_mismatch() {
  begin
  export STUB_CONNECTOR=DP-4
  run_wrapper true
  ne "fails on connector mismatch" "$RC" 0
  file_has "connector error logged" "$LOG" "Gamescope connector is 'DP-4', expected 'DP-3'"
}

test_precheck_kernel_fallback_ok() {
  begin
  unset STUB_MODE_LIST
  mkdir -p "$SANDBOX/drmsys"
  printf '3440x1440\n1920x1200\n' >"$SANDBOX/drmsys/drm-modes-DP-3"
  export DRM_MODES_GLOB="$SANDBOX/drmsys/drm-modes-*"
  run_wrapper true
  eq "proceeds via kernel ModeDB fallback" "$RC" 0
  file_has "fallback logged" "$LOG" "checking kernel ModeDB"
}

test_precheck_kernel_fallback_missing() {
  begin
  unset STUB_MODE_LIST
  mkdir -p "$SANDBOX/drmsys"
  printf '3440x1440\n1920x1080\n' >"$SANDBOX/drmsys/drm-modes-DP-3"
  export DRM_MODES_GLOB="$SANDBOX/drmsys/drm-modes-*"
  run_wrapper true
  ne "fails when kernel ModeDB lacks the mode" "$RC" 0
  file_has "mode error logged" "$LOG" "does not currently advertise 1920x1200@60"
}

test_switch_timeout() {
  begin
  export STUB_SET_DIRTY_NOOP=1
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

test_xwayland_sync_order() {
  begin
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
  xwayland_sync_order
  xwayland_sync_failure_fails_closed
  xwayland_server_missing_fails_closed
  recovery_restores_xwayland
  recovery_old_state_restores_xwayland
)

echo "steamlink-display wrapper test suite"
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

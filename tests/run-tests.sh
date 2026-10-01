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

# --- process lifecycle ------------------------------------------------------
# Every process a test starts is owned by that test and must be gone when the
# test ends, whatever its outcome. A surviving descendant that keeps the
# runner's stdout/stderr open makes the owner wait for an EOF that never comes:
# that is what hung the GitHub Actions run.
TEST_PIDS=()

track_pid() {
  # Own a process (already started) and record its lifecycle.
  TEST_PIDS+=("$1")
  printf 'PROCESS_STARTED pid=%s cmd=%s\n' "$1" "${2:-}" \
    >>"${STUB_STATE_DIR:-/dev/null}/background.log"
}

test_bg() {
  # Start "$@" in the background with its own descriptors (never the runner's)
  # and register the PID so the test cleanup can terminate it.
  "$@" >>"${STUB_STATE_DIR:-/dev/null}/background.log" 2>&1 &
  local pid=$!
  track_pid "$pid" "$*"
  printf '%s\n' "$pid"
}

cleanup_test_processes() {
  # TERM -> bounded wait -> KILL -> reap. Idempotent, safe to call twice.
  local pid deadline alive
  for pid in "${TEST_PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    printf 'PROCESS_STOP_REQUESTED pid=%s\n' "$pid" >>"${STUB_STATE_DIR:-/dev/null}/background.log"
    kill -TERM "$pid" 2>/dev/null || true
  done
  deadline=$((SECONDS + 5))
  while (( SECONDS < deadline )); do
    alive=0
    for pid in "${TEST_PIDS[@]:-}"; do
      [[ -n "$pid" ]] || continue
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    (( alive )) || break
    sleep 0.1
  done
  for pid in "${TEST_PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      printf 'PROCESS_TIMEOUT pid=%s (KILL fallback)\n' "$pid" >>"${STUB_STATE_DIR:-/dev/null}/background.log"
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    printf 'PROCESS_STOPPED pid=%s\n' "$pid" >>"${STUB_STATE_DIR:-/dev/null}/background.log"
  done
  TEST_PIDS=()
}

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
  unset STUB_SET_DIRTY_NOOP STUB_SET_DIRTY_FAIL STUB_SLEEP_FAIL STUB_WAKE_FAIL STUB_ALLOW_FAIL STUB_CONNECTOR STUB_NO_INFO STUB_REPICK_REFRESH STUB_STREAM_ACTIVE STUB_XWL_FAIL STUB_XWL_NOOP STUB_XWL1_ABSENT STUB_KSCREEN_AVAILABLE STUB_KSCREEN_CONNECTOR STUB_KSCREEN_MODE_LIST STUB_KSCREEN_CURRENT_MODE STUB_KSCREEN_PRIMARY STUB_KSCREEN_FAIL STUB_KRFB_FAIL STUB_KRFB_NO_OUTPUT STUB_KSCREEN_EXTRA STUB_SYSTEMD_STATE STUB_FORCE_ENABLE_FAIL STUB_STREAM_ON_SUBSCRIBE DRM_MODES_GLOB 2>/dev/null || true
  unset STREAM_MODE STREAM_CAPTURE_HINT_MAX_AGE_SECONDS STREAM_NO_COMPATIBLE_FALLBACK STREAM_ASPECT_TOLERANCE STEAM_STREAM_LOG STEAM_STREAM_LOG_PREV LOCAL_WIDTH LOCAL_HEIGHT LOCAL_REFRESH STREAM_ALT_REFRESHES 2>/dev/null || true
  export STUB_STREAM_ACTIVE=1
  mkdir -p "$HOME/.config/gamescope" "$XDG_CONFIG_HOME/steam-link-display-adapter" "$XDG_STATE_HOME/steam-link-display-adapter" "$STUB_STATE_DIR"
  rm -rf "$STUB_STATE_DIR/units" "$STUB_STATE_DIR/systemd-run.log"
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
  printf '3440x1440@165\n' >"$STUB_STATE_DIR/kscreen_mode"
  printf '3440x1440\n' >"$STUB_STATE_DIR/xwl1_mode"
  printf 'drm: selecting mode 3440x1440@165Hz\n' >"$STUB_STATE_DIR/journal"
  : >"$STUB_STATE_DIR/dynamic.log"
  : >"$STUB_STATE_DIR/sleep.log"
  RC=0
}

end() {
  # A test's end implies the end of every process the test started.
  cleanup_test_processes
  if [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]]; then rm -rf "$SANDBOX"; fi
  SANDBOX=""
}

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
  file_has "physical display sleep failure logged" "$LOG" "failed to sleep the physical display during Steam Link streaming"
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
  flock -n "$LOCKF" -c 'sleep 2' >/dev/null 2>&1 &
  local holder=$!
  track_pid "$holder" "flock $LOCKF"
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
    track_pid "$wp" "wrapper $sig run"
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


test_desktop_mode_happy_path() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "Desktop Mode exit code 0" "$RC" 0
  file_has "Desktop backend detected" "$LOG" "Display backend detected: Desktop/KScreen"
  file_has "Desktop target reached" "$LOG" "OUTPUT_TARGET_REACHED 1920x1200@60"
  cmp_file "Desktop mode restored" "$STUB_STATE_DIR/kscreen_mode" '3440x1440@165'
  cmp_file "Desktop modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  absent "Desktop state cleared" "$STATE_DIR/state"
}

test_desktop_mode_without_stream_bypasses() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
  unset STUB_STREAM_ACTIVE
  run_wrapper true
  eq "Desktop no-stream exit code 0" "$RC" 0
  file_has "Desktop no-stream bypass logged" "$LOG" "bypassing display pipeline"
  cmp_file "Desktop no-stream mode untouched" "$STUB_STATE_DIR/kscreen_mode" '3440x1440@165'
  file_lacks "Desktop no-stream target not applied" "$STUB_STATE_DIR/kscreen.log" '1920x1200@60'
}

test_desktop_mode_delayed_stream() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=HDMI-A-1
  export STUB_KSCREEN_MODE_LIST="2560x1440@144 1920x1080@60"
  printf '2560x1440@144\n' >"$STUB_STATE_DIR/kscreen_mode"
  printf 'STREAM_DETECT_WAIT_SECONDS=3\n' >"$CFG"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1080 60.00 FPS'
  unset STUB_STREAM_ACTIVE
  export STUB_STREAM_ON_SUBSCRIBE=1
  run_wrapper true
  eq "Desktop delayed stream exit code 0" "$RC" 0
  file_has "Desktop delayed stream detected" "$LOG" "Steam Link streaming session detected"
  file_has "Desktop delayed target reached" "$LOG" "OUTPUT_TARGET_REACHED 1920x1080@60"
  cmp_file "Desktop delayed stream restored" "$STUB_STATE_DIR/kscreen_mode" '2560x1440@144'
}


test_desktop_mode_isolated_from_gamescope() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-1
  export STUB_KSCREEN_MODE_LIST="2560x1440@144 1920x1080@60"
  printf '2560x1440@144\n' >"$STUB_STATE_DIR/kscreen_mode"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1080 60.00 FPS'
  run_wrapper true
  eq "Desktop backend does not require gamescope" "$RC" 0
  file_lacks "Desktop run did not invoke Gamescope dynamic modes" "$STUB_STATE_DIR/dynamic.log" '^1$'
  file_lacks "Desktop run did not sleep external screen" "$STUB_STATE_DIR/sleep.log" '^1$'
  cmp_file "Desktop backend restores its own mode" "$STUB_STATE_DIR/kscreen_mode" '2560x1440@144'
}

test_gamescope_mode_isolated_from_kscreen() {
  begin
  # Gamescope is available and the KScreen stub too: the Gamescope path must
  # never touch KScreen.
  export STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "Gamescope path runs with KScreen present" "$RC" 0
  file_has "Gamescope backend selected" "$LOG" "Display backend detected: Gamescope"
  cmp_file "Gamescope did not drive KScreen" "$STUB_STATE_DIR/kscreen_mode" '3440x1440@165'
  absent "Gamescope made no KScreen mode change" "$STUB_STATE_DIR/kscreen.log"
}

test_desktop_backend_redetected_after_recovery() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  # An interrupted Desktop run left the output at the streamed mode.
  printf '1920x1200@60\n' >"$STUB_STATE_DIR/kscreen_mode"
  {
    printf 'VERSION=1\n'
    printf 'PHASE=STREAMING\n'
    printf 'MODES_BACKUP=%s\n' "$BACKUP"
    printf 'MODES_EXISTED=0\n'
    printf 'SCREEN_SLEEP_REQUESTED=0\n'
    printf 'XWAYLAND_SYNCED=0\n'
    printf 'DISPLAY_BACKEND=desktop\n'
    printf 'ORIGINAL_CONNECTOR=DP-3\n'
    printf 'ORIGINAL_MODE=3440x1440@165\n'
    printf 'ORIGINAL_XWAYLAND_MODE=\n'
    printf 'DISPLAY_DESCRIPTION=DP-3\n'
  } >"$STATE_DIR/state"
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
  unset STUB_STREAM_ACTIVE
  run_wrapper true
  eq "Desktop recovery run exits 0" "$RC" 0
  file_has "Desktop recovery completed" "$LOG" "Stale-state recovery complete"
  file_has "Desktop recovery restored the saved mode" "$LOG" "Verified original Desktop mode: 3440x1440@165"
  cmp_file "Desktop output back to the original mode" "$STUB_STATE_DIR/kscreen_mode" '3440x1440@165'
  absent "Desktop recovered state cleared" "$STATE_DIR/state"
  file_has "backend re-detected after recovery" "$LOG" "Display backend detected: Desktop/KScreen"
  file_has "bypass after recovery" "$LOG" "bypassing display pipeline"
}

# --- single physical-display behaviour (no monitor policy) -------------------

test_gamescope_physical_display_sleep() {
  begin
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "Gamescope stream run exits 0" "$RC" 0
  file_has "physical display slept during the stream" "$STUB_STATE_DIR/sleep.log" '^1$'
  file_has "physical display woken during cleanup" "$STUB_STATE_DIR/sleep.log" '^0$'
  file_has "the sleep is logged" "$LOG" "PHYSICAL_DISPLAY_SLEEPING"
  file_has "the restore is logged" "$LOG" "PHYSICAL_DISPLAY_RESTORED"
  cmp_file "modes.cfg restored" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
}

test_desktop_layout_verification() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  # The stub silently ignores the saved position while returning success. The
  # post-restore verification compares the final KScreen state with the saved
  # profile and must surface the mismatch.
  #
  # The physical primary is deliberately NOT used here: when the temporary
  # virtual output disappears the compositor promotes another output, so the
  # primary flag converges anyway and the mismatch would not be observable
  # (measured 2026-10-01).
  export STUB_KSCREEN_NOOP='position:DP-3'
  printf '1920x1200@60\n' >"$STUB_STATE_DIR/kscreen_mode"
  {
    printf 'VERSION=1\n'
    printf 'PHASE=STREAMING\n'
    printf 'MODES_BACKUP=%s\n' "$BACKUP"
    printf 'MODES_EXISTED=0\n'
    printf 'SCREEN_SLEEP_REQUESTED=0\n'
    printf 'VIRTUAL_DISPLAY_ACTIVE=0\n'
    printf 'XWAYLAND_SYNCED=0\n'
    printf 'DISPLAY_BACKEND=desktop\n'
    printf 'ORIGINAL_CONNECTOR=DP-3\n'
    printf 'ORIGINAL_PRIMARY_OUTPUT=DP-3\n'
    printf 'ORIGINAL_DESKTOP_LAYOUT=DP-3|1|1|1|3440x1440@165|1234,0|1|1\n'
    printf 'ORIGINAL_MODE=3440x1440@165\n'
    printf 'ORIGINAL_XWAYLAND_MODE=\n'
    printf 'DISPLAY_DESCRIPTION=DP-3\n'
  } >"$STATE_DIR/state"
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
  unset STUB_STREAM_ACTIVE
  run_wrapper true
  eq "layout verification does not change the successful game exit code" "$RC" 0
  file_has "post-restore layout mismatch is detected" "$LOG" "Desktop layout verification: output 'DP-3' position="
  file_has "layout verification failure is logged" "$LOG" "DESKTOP_LAYOUT_VERIFY_FAILED"
  exists "state is kept when the post-restore verification fails" "$STATE_DIR/state"
}

test_monitor_option_removed() {
  begin
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  local form
  for form in "--monitor on" "--monitor off" "--monitor=on" "--monitor=off"; do
    rm -f "$LOG"
    : >"$STUB_STATE_DIR/sleep.log"
    : >"$STUB_STATE_DIR/kscreen.log"
    # shellcheck disable=SC2086
    run_wrapper $form true
    ne "rejected: $form" "$RC" 0
    file_lacks "no game launch for $form" "$LOG" "GAME_LAUNCH"
    file_lacks "no stream pipeline for $form" "$LOG" "STREAM_DETECTED"
    eq "no screen sleep for $form" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
    eq "no kscreen change for $form" "$(cat "$STUB_STATE_DIR/kscreen.log")" ""
    absent "no state written for $form" "$STATE_DIR/state"
    cmp_file "modes.cfg untouched by $form" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  done
}

test_monitor_forms_are_game_arguments() {
  begin
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  # After the game command the same tokens are ordinary game arguments: they
  # are forwarded verbatim and never parsed as wrapper options.
  run_wrapper bash -c 'printf "%s\n" "$@" > "$0"' "$SANDBOX/game_args" --monitor on
  eq "a game command carrying --monitor exits 0" "$RC" 0
  cmp_file "game argv preserved verbatim" "$SANDBOX/game_args" $'--monitor\non'
}

test_gamescope_wake_failure() {
  begin
  export STUB_WAKE_FAIL=1
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "run still exits 0" "$RC" 0
  file_has "wake failure diagnosed" "$LOG" "CRITICAL: failed to restore the physical display"
  cmp_file "modes.cfg restored despite the wake failure" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
}

test_desktop_physical_display_disable() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "Desktop default run exits 0" "$RC" 0
  file_has "Desktop virtual display created" "$LOG" "VIRTUAL_DISPLAY_CREATED"
  file_has "Desktop virtual display selected" "$STUB_STATE_DIR/kscreen.log" 'primary'
  file_has "Desktop physical output disabled after virtual output is ready" "$STUB_STATE_DIR/kscreen.log" 'disable DP-3'
  file_has "Desktop physical output re-enabled during cleanup" "$STUB_STATE_DIR/kscreen.log" 'enable DP-3'
  file_has "Desktop virtual display destroyed" "$LOG" "VIRTUAL_DISPLAY_DESTROYED"
  file_has "Desktop final layout verified" "$LOG" "Verified Desktop layout after restore"
  cmp_file "Desktop original mode restored" "$STUB_STATE_DIR/kscreen_mode" '3440x1440@165'
  cmp_file "Desktop original primary restored" "$STUB_STATE_DIR/kscreen_primary" 'DP-3'
  absent "Desktop virtual display process marker removed" "$STUB_STATE_DIR/virtual_display_present"
}

# --- shared fixture: a run interrupted at a point of the virtual lifecycle ----
# Usage: seed_virtual_crash_state <phase> <unit> <output> <virtual_primary> <sleep>
seed_virtual_crash_state() {
  local phase=$1 unit_active=$2 output_present=$3 virtual_primary=$4 sleep_requested=$5
  local unit=steam-link-virtual-SteamLinkDisplayAdapter.service pid

  if (( unit_active )); then
    mkdir -p "$STUB_STATE_DIR/units"
    (
      : >"$STUB_STATE_DIR/virtual_display_present"
      trap 'rm -f "$STUB_STATE_DIR/virtual_display_present"; exit 0' TERM INT
      deadline=$((SECONDS + 60))
      while (( SECONDS < deadline )); do sleep 0.2; done
    ) >"$STUB_STATE_DIR/background.log" 2>&1 &
    pid=$!
    track_pid "$pid" "virtual display unit ($phase)"
    printf '%s\n' "$pid" >"$STUB_STATE_DIR/units/$unit"
  elif (( output_present )); then
    : >"$STUB_STATE_DIR/virtual_display_present"
  fi

  if (( output_present || unit_active )); then
    printf 'SteamLinkDisplayAdapter\n' >"$STUB_STATE_DIR/virtual_display_name"
    printf '1920x1200\n' >"$STUB_STATE_DIR/virtual_display_resolution"
    : >"$STUB_STATE_DIR/kscreen_physical_disabled"
  fi
  if (( virtual_primary )); then
    printf 'Virtual-SteamLinkDisplayAdapter\n' >"$STUB_STATE_DIR/kscreen_primary"
  else
    printf 'DP-3\n' >"$STUB_STATE_DIR/kscreen_primary"
  fi

  {
    printf 'VERSION=1\n'
    printf 'PHASE=%s\n' "$phase"
    printf 'MODES_BACKUP=%s\n' "$BACKUP"
    printf 'MODES_EXISTED=1\n'
    printf 'SCREEN_SLEEP_REQUESTED=%s\n' "$sleep_requested"
    printf 'VIRTUAL_DISPLAY_ACTIVE=%s\n' "$unit_active"
    printf 'VIRTUAL_DISPLAY_UNIT=%s\n' "$( (( unit_active )) && printf '%s' "$unit" )"
    printf 'VIRTUAL_DISPLAY_PORT=59100\n'
    printf 'VIRTUAL_DISPLAY_NAME=SteamLinkDisplayAdapter\n'
    printf 'VIRTUAL_DISPLAY_OUTPUT=Virtual-SteamLinkDisplayAdapter\n'
    printf 'XWAYLAND_SYNCED=0\n'
    printf 'DISPLAY_BACKEND=desktop\n'
    printf 'STREAM_MODE=auto\n'
    printf 'TARGET_WIDTH=1920\nTARGET_HEIGHT=1200\nTARGET_REFRESH=60\n'
    printf 'TARGET_SOURCE=steam_capture_hint\n'
    printf 'ORIGINAL_CONNECTOR=DP-3\n'
    printf 'ORIGINAL_PRIMARY_OUTPUT=DP-3\n'
    printf 'ORIGINAL_DESKTOP_LAYOUT=%s\n' "DP-3|1|1|1|3440x1440@165|0,0|1|1;HDMI-A-1|1|0|2|1920x1080@60|1920,0|1|1"
    printf 'ORIGINAL_MODE=3440x1440@165\n'
    printf 'ORIGINAL_XWAYLAND_MODE=\n'
    printf 'DISPLAY_DESCRIPTION=DP-3\n'
  } >"$STATE_DIR/state"
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
}

_crash_common_env() {
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  export STUB_KSCREEN_EXTRA="HDMI-A-1|1920x1080@60|1920,0|1|1|2|1|0"
  unset STUB_STREAM_ACTIVE
}

_crash_asserts() {
  local label=$1
  eq "$label: recovery exits 0" "$RC" 0
  file_has "$label: layout restored" "$LOG" "Restoring Desktop layout"
  cmp_file "$label: original primary restored" "$STUB_STATE_DIR/kscreen_primary" 'DP-3'
  absent "$label: physical output re-enabled" "$STUB_STATE_DIR/kscreen_physical_disabled"
  absent "$label: virtual output gone" "$STUB_STATE_DIR/virtual_display_present"
  absent "$label: unit stopped" "$STUB_STATE_DIR/units/steam-link-virtual-SteamLinkDisplayAdapter.service"
  absent "$label: state cleared" "$STATE_DIR/state"
}

test_desktop_virtual_crash_before_unit() {
  begin
  _crash_common_env
  seed_virtual_crash_state PREPARING 0 0 0 0
  run_wrapper true
  _crash_asserts "crash before unit"
}

test_desktop_virtual_crash_unit_without_output() {
  begin
  _crash_common_env
  seed_virtual_crash_state PREPARING 1 0 0 0
  run_wrapper true
  _crash_asserts "crash with unit, no output"
}

test_desktop_virtual_crash_output_without_primary() {
  begin
  _crash_common_env
  seed_virtual_crash_state PREPARED 1 1 0 0
  run_wrapper true
  _crash_asserts "crash with output, no virtual primary"
}

test_desktop_virtual_crash_streaming_with_virtual_primary() {
  begin
  _crash_common_env
  seed_virtual_crash_state STREAMING 1 1 1 1
  run_wrapper true
  _crash_asserts "crash while streaming"
}

test_desktop_virtual_three_monitors() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  export STUB_KSCREEN_EXTRA="HDMI-A-1|1920x1080@60|1920,0|1|1|2|1|0 DP-2|1920x1080@60|3840,0|1|1|3|1|0"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "three-monitor virtual run exits 0" "$RC" 0
  file_has "virtual display created" "$LOG" "VIRTUAL_DISPLAY_CREATED"
  file_has "target output disabled" "$STUB_STATE_DIR/kscreen.log" 'disable DP-3'
  file_lacks "second monitor untouched" "$STUB_STATE_DIR/kscreen.log" 'disable HDMI-A-1'
  file_lacks "third monitor untouched" "$STUB_STATE_DIR/kscreen.log" 'disable DP-2'
  file_has "second monitor restored position" "$STUB_STATE_DIR/kscreen.log" 'position HDMI-A-1 1920,0'
  file_has "third monitor restored position" "$STUB_STATE_DIR/kscreen.log" 'position DP-2 3840,0'
  cmp_file "original primary restored" "$STUB_STATE_DIR/kscreen_primary" 'DP-3'
  absent "virtual display removed" "$STUB_STATE_DIR/virtual_display_present"
}

test_desktop_virtual_readiness_before_launch() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "virtual run exits 0" "$RC" 0
  # the game must be launched only after the virtual canvas exists
  local created launched
  created=$(grep -n 'VIRTUAL_DISPLAY_CREATED' "$LOG" | head -n1 | cut -d: -f1)
  launched=$(grep -n 'Launching game:' "$LOG" | head -n1 | cut -d: -f1)
  [[ -n "$created" && -n "$launched" && "$created" -lt "$launched" ]] \
    && say_pass "virtual display ready before the game launch" \
    || say_fail "virtual display ready before the game launch (created=$created launched=$launched)"
  file_has "physical output disabled only after readiness" "$STUB_STATE_DIR/kscreen.log" 'disable DP-3'
}





test_desktop_virtual_display_failure_fails_closed() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KRFB_FAIL=1
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  ne "Desktop virtual display failure returns non-zero" "$RC" 0
  file_has "virtual display failure logged" "$LOG" "virtual stream display unit exited before the output appeared"
  file_lacks "no game launch on virtual display failure" "$LOG" "GAME_LAUNCH"
  absent "state cleared after the failed run" "$STATE_DIR/state"
}

test_desktop_wake_failure() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_FAIL=0
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  export STUB_FORCE_ENABLE_FAIL=1
  run_wrapper true
  eq "run still exits 0" "$RC" 0
  file_has "wake failure diagnosed" "$LOG" "CRITICAL: display backend restore failed"
  cmp_file "Desktop original mode still restored" "$STUB_STATE_DIR/kscreen_mode" '3440x1440@165'
  absent "state cleared" "$STATE_DIR/state"
}

test_desktop_recovery_wake() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  # An interrupted Desktop run left the physical output out of the layout.
  printf '1920x1200@60\n' >"$STUB_STATE_DIR/kscreen_mode"
  {
    printf 'VERSION=1\n'
    printf 'PHASE=STREAMING\n'
    printf 'MODES_BACKUP=%s\n' "$BACKUP"
    printf 'MODES_EXISTED=0\n'
    printf 'SCREEN_SLEEP_REQUESTED=1\n'
    printf 'XWAYLAND_SYNCED=0\n'
    printf 'DISPLAY_BACKEND=desktop\n'
    printf 'ORIGINAL_CONNECTOR=DP-3\n'
    printf 'ORIGINAL_MODE=3440x1440@165\n'
    printf 'ORIGINAL_XWAYLAND_MODE=\n'
    printf 'DISPLAY_DESCRIPTION=DP-3\n'
  } >"$STATE_DIR/state"
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
  unset STUB_STREAM_ACTIVE
  run_wrapper true
  eq "Desktop recovery exits 0" "$RC" 0
  file_has "Desktop recovery restored the physical display" "$LOG" "PHYSICAL_DISPLAY_RESTORED"
  file_has "Desktop recovery re-enabled the physical output" "$STUB_STATE_DIR/kscreen.log" 'enable DP-3'
  cmp_file "Desktop original mode restored" "$STUB_STATE_DIR/kscreen_mode" '3440x1440@165'
  absent "Desktop recovered state cleared" "$STATE_DIR/state"
}

test_desktop_restore_detects_silent_kscreen_rejection() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_REJECT=1
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  # kscreen-doctor exits 0 while rejecting the request, so the wrapper must not
  # trust the exit code: a rejected restore has to surface and the stale state
  # must be kept instead of being silently cleared as if it had worked.
  printf '1920x1200@60\n' >"$STUB_STATE_DIR/kscreen_mode"
  {
    printf 'VERSION=1\n'
    printf 'PHASE=STREAMING\n'
    printf 'MODES_BACKUP=%s\n' "$BACKUP"
    printf 'MODES_EXISTED=0\n'
    printf 'SCREEN_SLEEP_REQUESTED=0\n'
    printf 'VIRTUAL_DISPLAY_ACTIVE=0\n'
    printf 'XWAYLAND_SYNCED=0\n'
    printf 'DISPLAY_BACKEND=desktop\n'
    printf 'ORIGINAL_CONNECTOR=DP-3\n'
    printf 'ORIGINAL_MODEL=DP-3\n'
    printf 'ORIGINAL_PRIMARY_OUTPUT=DP-3\n'
    printf 'ORIGINAL_DESKTOP_LAYOUT=DP-3|1|1|1|3440x1440@165.00|0,0|1|1\n'
    printf 'ORIGINAL_MODE=3440x1440@165\n'
    printf 'ORIGINAL_XWAYLAND_MODE=\n'
    printf 'DISPLAY_DESCRIPTION=DP-3\n'
  } >"$STATE_DIR/state"
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
  unset STUB_STREAM_ACTIVE
  run_wrapper true
  file_has "the rejected restore is surfaced by the postcondition" "$LOG" "DESKTOP_LAYOUT_VERIFY_FAILED"
  exists "the stale state is kept when the restore could not be trusted" "$STATE_DIR/state"
  cmp_file "the output was not silently treated as restored" "$STUB_STATE_DIR/kscreen_mode" '1920x1200@60'
}

test_desktop_layout_restore_normalizes_snapshot_mode() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  # A KScreen snapshot reports the refresh with two decimals ("@165.00").
  # The restore must normalize it: kscreen-doctor rejects the raw token and
  # still exits 0, so the mistake would otherwise leave the output unrestored
  # without any error reaching the wrapper.
  printf '1920x1200@60\n' >"$STUB_STATE_DIR/kscreen_mode"
  {
    printf 'VERSION=1\n'
    printf 'PHASE=STREAMING\n'
    printf 'MODES_BACKUP=%s\n' "$BACKUP"
    printf 'MODES_EXISTED=0\n'
    printf 'SCREEN_SLEEP_REQUESTED=0\n'
    printf 'VIRTUAL_DISPLAY_ACTIVE=0\n'
    printf 'XWAYLAND_SYNCED=0\n'
    printf 'DISPLAY_BACKEND=desktop\n'
    printf 'ORIGINAL_CONNECTOR=DP-3\n'
    printf 'ORIGINAL_PRIMARY_OUTPUT=DP-3\n'
    printf 'ORIGINAL_DESKTOP_LAYOUT=DP-3|1|1|1|3440x1440@165.00|0,0|1|1\n'
    printf 'ORIGINAL_MODE=3440x1440@165.00\n'
    printf 'ORIGINAL_XWAYLAND_MODE=\n'
    printf 'DISPLAY_DESCRIPTION=DP-3\n'
  } >"$STATE_DIR/state"
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
  unset STUB_STREAM_ACTIVE
  run_wrapper true
  eq "raw snapshot recovery exits 0" "$RC" 0
  cmp_file "snapshot mode restored in normalized form" "$STUB_STATE_DIR/kscreen_mode" '3440x1440@165'
  cmp_file "original primary restored from the raw layout" "$STUB_STATE_DIR/kscreen_primary" 'DP-3'
  absent "state cleared after the raw snapshot recovery" "$STATE_DIR/state"
}

test_bypass_no_stream_no_display_change() {
  begin
  unset STUB_STREAM_ACTIVE
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
  run_wrapper true
  eq "a local launch exits 0" "$RC" 0
  file_has "bypass logged" "$LOG" "bypassing display pipeline"
  eq "no physical display sleep on bypass" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  eq "no kscreen change on bypass" "$(cat "$STUB_STATE_DIR/kscreen.log")" ""
}

# --- virtual stream display: multi-monitor, capability, crash states ---------

test_desktop_virtual_multi_monitor() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  # second physical output: DP-3 is primary, HDMI-A-1 sits right of it
  export STUB_KSCREEN_EXTRA="HDMI-A-1|1920x1080@60|1920,0|1|1|2|1|0"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "multi-monitor virtual run exits 0" "$RC" 0
  file_has "virtual display created" "$LOG" "VIRTUAL_DISPLAY_CREATED"
  file_has "target physical output disabled" "$STUB_STATE_DIR/kscreen.log" 'disable DP-3'
  file_lacks "other monitor never disabled" "$STUB_STATE_DIR/kscreen.log" 'disable HDMI-A-1'
  file_has "layout restore re-enables the physical output" "$STUB_STATE_DIR/kscreen.log" 'enable DP-3'
  file_has "layout restore repositions the other monitor" "$STUB_STATE_DIR/kscreen.log" 'position HDMI-A-1 1920,0'
  file_has "layout restore repositions the physical output" "$STUB_STATE_DIR/kscreen.log" 'position DP-3 0,0'
  cmp_file "original primary restored" "$STUB_STATE_DIR/kscreen_primary" 'DP-3'
  absent "virtual display removed" "$STUB_STATE_DIR/virtual_display_present"
}

test_desktop_virtual_geometry_not_on_physical() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  # the physical host advertises ONE mode only; the client asks for another one.
  export STUB_KSCREEN_MODE_LIST="3440x1440@165"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  eq "virtual geometry accepted without a matching physical mode" "$RC" 0
  file_has "virtual display created at the client geometry" "$LOG" "VIRTUAL_DISPLAY_CREATED Virtual-SteamLinkDisplayAdapter/1920x1200"
  file_lacks "no physical-mode complaint" "$LOG" "does not currently advertise"
  file_has "target reached" "$LOG" "OUTPUT_TARGET_REACHED 1920x1200@60"
}

test_desktop_virtual_unit_without_output_fails_closed() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KRFB_NO_OUTPUT=1
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper true
  ne "missing virtual output fails closed" "$RC" 0
  file_has "missing output diagnosed" "$LOG" "did not appear within"
  file_lacks "no game launch without the virtual canvas" "$LOG" "GAME_LAUNCH"
  absent "physical output never disabled" "$STUB_STATE_DIR/kscreen_physical_disabled"
}

test_desktop_virtual_recovery_after_crash() {
  begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST="3440x1440@165 1920x1200@60"
  export STUB_KSCREEN_EXTRA="HDMI-A-1|1920x1080@60|1920,0|1|1|2|1|0"
  # a crashed run: virtual output + unit still alive, physical disabled
  printf 'SteamLinkDisplayAdapter
' >"$STUB_STATE_DIR/virtual_display_name"
  printf '1920x1200
' >"$STUB_STATE_DIR/virtual_display_resolution"
  : >"$STUB_STATE_DIR/kscreen_physical_disabled"
  # emulates the krfb payload: the virtual output exists while the process
  # lives and disappears when the unit is stopped (SIGTERM).
  (
    : >"$STUB_STATE_DIR/virtual_display_present"
    trap 'rm -f "$STUB_STATE_DIR/virtual_display_present"; exit 0' TERM INT
    deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do sleep 0.2; done
  ) >"$STUB_STATE_DIR/background.log" 2>&1 &
  local vpid=$!
  track_pid "$vpid" "simulated virtual display unit"
  mkdir -p "$STUB_STATE_DIR/units"
  printf '%s\n' "$vpid" >"$STUB_STATE_DIR/units/steam-link-virtual-SteamLinkDisplayAdapter.service"
  {
    printf 'VERSION=1\n'
    printf 'PHASE=STREAMING\n'
    printf 'MODES_BACKUP=%s\n' "$BACKUP"
    printf 'MODES_EXISTED=0\n'
    printf 'SCREEN_SLEEP_REQUESTED=0\n'
    printf 'VIRTUAL_DISPLAY_ACTIVE=1\n'
    printf 'VIRTUAL_DISPLAY_UNIT=steam-link-virtual-SteamLinkDisplayAdapter.service\n'
    printf 'VIRTUAL_DISPLAY_NAME=SteamLinkDisplayAdapter\n'
    printf 'VIRTUAL_DISPLAY_OUTPUT=Virtual-SteamLinkDisplayAdapter\n'
    printf 'XWAYLAND_SYNCED=0\n'
    printf 'DISPLAY_BACKEND=desktop\n'
    printf 'ORIGINAL_CONNECTOR=DP-3\n'
    printf 'ORIGINAL_PRIMARY_OUTPUT=DP-3\n'
    printf 'ORIGINAL_DESKTOP_LAYOUT=DP-3|1|1|1|3440x1440@165|0,0|1|1;HDMI-A-1|1|0|2|1920x1080@60|1920,0|1|1\n'
    printf 'ORIGINAL_MODE=3440x1440@165\n'
    printf 'ORIGINAL_XWAYLAND_MODE=\n'
    printf 'DISPLAY_DESCRIPTION=DP-3\n'
  } >"$STATE_DIR/state"
  printf 'STREAM_DETECT_WAIT_SECONDS=1\n' >"$CFG"
  unset STUB_STREAM_ACTIVE
  run_wrapper true
  eq "crash recovery exits 0" "$RC" 0
  file_has "virtual display torn down" "$LOG" "VIRTUAL_DISPLAY_DESTROYED"
  file_has "layout restored" "$LOG" "Restoring Desktop layout"
  file_has "final layout verified after crash" "$LOG" "Verified Desktop layout after restore"
  cmp_file "primary restored after crash" "$STUB_STATE_DIR/kscreen_primary" 'DP-3'
  absent "stale virtual output removed" "$STUB_STATE_DIR/virtual_display_present"
  absent "recovered state cleared" "$STATE_DIR/state"
  absent "unit stopped" "$STUB_STATE_DIR/units/steam-link-virtual-SteamLinkDisplayAdapter.service"
}

test_backend_precheck_missing_gamescope_dependency() {
  begin
  export STUB_NO_INFO=1
  export DISPLAY_BACKEND=gamescope
  run_wrapper true
  eq "wrapper bypasses when Gamescope backend is unavailable" "$RC" 0
  file_has "no backend bypass logged" "$LOG" "No supported display backend detected: bypassing display pipeline"
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
  file_has "no display backend bypass noted" "$LOG" "No supported display backend detected: bypassing display pipeline"
  file_lacks "no detection window in Desktop Mode" "$LOG" "STREAM_WAIT_START"
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  eq "no dynamic toggles" "$(cat "$STUB_STATE_DIR/dynamic.log")" ""
}

test_bypass_ignores_lock() {
  begin
  unset STUB_STREAM_ACTIVE
  : >"$LOCKF"
  flock -n "$LOCKF" -c 'sleep 2' >/dev/null 2>&1 &
  local holder=$!
  track_pid "$holder" "flock $LOCKF"
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
  export STUB_STREAM_ON_SUBSCRIBE=1
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
  export STUB_STREAM_ON_SUBSCRIBE=1
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
  export STUB_STREAM_ON_SUBSCRIBE=1
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
    export STUB_STREAM_ON_SUBSCRIBE=1
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
  export STUB_STREAM_ON_SUBSCRIBE=1
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


# --- CLI surface (spec 2026-09-30: the --mode override is removed) ----------

test_cli_mode_rejected() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  # A stale state must keep the fail-fast property: rejection happens before
  # any recovery, display mutation or state change.
  seed_stale_state
  local v
  for v in "--mode" "--mode auto" "--mode 1920x1200" "--mode=1920x1200" \
           "--mode 1920x1200@60" "--mode 1920x1200 --mode 1280x800"; do
    rm -f "$LOG"
    # shellcheck disable=SC2086
    run_wrapper $v true
    ne "rejects '$v'" "$RC" 0
    file_has "'$v' explains --mode is unsupported" "$LOG" "no longer supported"
    file_lacks "'$v' no GAME_LAUNCH" "$LOG" "GAME_LAUNCH"
    eq "'$v' no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
    eq "'$v' no dynamic toggles" "$(cat "$STUB_STATE_DIR/dynamic.log")" ""
    cmp_file "'$v' modes.cfg untouched" "$MODESF" 'StubMake StubModel:1920x1200@60'
    file_has "'$v' stale state untouched" "$STATE_DIR/state" "PHASE=STREAMING"
  done
  end
}

test_cli_unsupported_options() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  rm -f "$LOG"
  run_wrapper --foo bar true
  ne "unknown wrapper option rejected" "$RC" 0
  file_has "unknown logged" "$LOG" "unknown wrapper option: --foo"
  file_lacks "unknown option does not launch" "$LOG" "GAME_LAUNCH"
  rm -f "$LOG"
  run_wrapper
  ne "missing game command rejected" "$RC" 0
  file_has "usage shown on missing command" "$STDERR" "Usage:"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  end
}

test_help_minimal() {
  begin
  run_wrapper --help
  eq "help exits 0" "$RC" 0
  file_has "usage printed" "$STDERR" "Usage:"
  file_has "public launch option shown" "$STDERR" "%command%"
  file_lacks "no --monitor in help" "$STDERR" "--monitor"
  file_lacks "no monitor policy in help" "$STDERR" "monitor on"
  file_lacks "no --mode in help" "$STDERR" "--mode"
  file_lacks "no WxH in help" "$STDERR" "WxH"
  absent "no state written" "$STATE_DIR/state"
  eq "no screen sleep" "$(cat "$STUB_STATE_DIR/sleep.log")" ""
  cmp_file "modes.cfg untouched" "$MODESF" 'StubMake StubModel:3440x1440@165 0'
  end
}

test_game_argv_preserved() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  use_steam_log
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  run_wrapper bash -c 'printf "%s\n" "$@" > "$0"' "$SANDBOX/game_args" --arg1 foo --arg2 bar
  eq "runs" "$RC" 0
  cmp_file "game argv preserved verbatim" "$SANDBOX/game_args" $'--arg1\nfoo\n--arg2\nbar'
  file_has "game launched through the pipeline" "$LOG" "GAME_LAUNCH"
  end
}

test_config_mode_selection() {
  # With no CLI, the only decision is the internal STREAM_MODE.
  begin
  use_steam_log
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  printf 'STREAM_MODE=fixed\n' >"$CFG"
  run_wrapper true
  eq "fixed config runs" "$RC" 0
  file_has "fixed target" "$LOG" "TARGET_MODE_RESOLVED 1920x1200@60 source=fixed"
  file_lacks "hint not read in fixed mode" "$LOG" "CLIENT_HINT"
  end
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  run_wrapper true
  eq "auto default runs" "$RC" 0
  file_has "host original source" "$LOG" "source=host_original"
  file_lacks "no cli source in the log" "$LOG" "source=cli"
  file_lacks "no MODE_SOURCE log line" "$LOG" "MODE_SOURCE="
  end
}

test_state_target_fields() {
  begin
  export STUB_MODE_LIST="3440x1440@165 1920x1200@60"
  printf 'STREAM_MODE=fixed\n' >"$CFG"
  set -m
  bash "$WRAPPER" sleep 30 >"$STDOUT" 2>"$STDERR" &
  local wp=$!
  track_pid "$wp" "wrapper fixed-mode run"
  set +m
  local i=0
  while (( i < 150 )); do
    if [[ -f "$LOG" ]] && grep -q "Game PID:" "$LOG"; then break; fi
    sleep 0.1; i=$((i + 1))
  done
  file_has "state TARGET_WIDTH" "$STATE_DIR/state" "TARGET_WIDTH=1920"
  file_has "state TARGET_HEIGHT" "$STATE_DIR/state" "TARGET_HEIGHT=1200"
  file_has "state TARGET_SOURCE fixed" "$STATE_DIR/state" "TARGET_SOURCE=fixed"
  file_has "state TARGET_MODE_SPEC" "$STATE_DIR/state" "TARGET_MODE_SPEC=1920x1200@60"
  file_has "state ORIGINAL_CONNECTOR" "$STATE_DIR/state" "ORIGINAL_CONNECTOR=DP-3"
  file_has "state ORIGINAL_MODE" "$STATE_DIR/state" "ORIGINAL_MODE=3440x1440@165"
  file_has "state ORIGINAL_XWAYLAND_MODE" "$STATE_DIR/state" "ORIGINAL_XWAYLAND_MODE=3440x1440"
  file_has "state DISPLAY_DESCRIPTION" "$STATE_DIR/state" "DISPLAY_DESCRIPTION=StubMake StubModel"
  file_lacks "no cli source in state" "$STATE_DIR/state" "TARGET_SOURCE=cli"
  file_lacks "no MODE_SOURCE in state" "$STATE_DIR/state" "MODE_SOURCE"
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
  file_has "help shows new executable" "$STDERR" '%command%'
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
  exists "display backend facade" "$PKG_DIR/lib/display/backend.sh"
  exists "gamescope display backend" "$PKG_DIR/lib/display/gamescope.sh"
  exists "desktop display backend" "$PKG_DIR/lib/display/desktop.sh"
  for d in core detection display logging resolution state system xwayland; do
    exists "library area $d" "$PKG_DIR/lib/$d"
  done
  # library files are loaded with source: never executable
  for l in core/bootstrap.sh core/workflow.sh logging/logging.sh detection/steam-link.sh \
           display/connector.sh display/mode.sh display/profile.sh display/backend.sh \
           display/gamescope.sh display/desktop.sh resolution/resolver.sh \
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
           ANALISI-RIMOZIONE-MODALITA-CLI.md \
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
  desktop_mode_happy_path
  desktop_mode_without_stream_bypasses
  desktop_mode_delayed_stream
  desktop_mode_isolated_from_gamescope
  gamescope_mode_isolated_from_kscreen
  desktop_backend_redetected_after_recovery
  gamescope_physical_display_sleep
  monitor_option_removed
  desktop_layout_verification
  monitor_forms_are_game_arguments
  gamescope_wake_failure
  desktop_physical_display_disable
  desktop_virtual_display_failure_fails_closed
  desktop_wake_failure
  desktop_recovery_wake
  desktop_layout_restore_normalizes_snapshot_mode
  desktop_restore_detects_silent_kscreen_rejection
  bypass_no_stream_no_display_change
  desktop_virtual_multi_monitor
  desktop_virtual_geometry_not_on_physical
  desktop_virtual_unit_without_output_fails_closed
  desktop_virtual_recovery_after_crash
  desktop_virtual_crash_before_unit
  desktop_virtual_crash_unit_without_output
  desktop_virtual_crash_output_without_primary
  desktop_virtual_crash_streaming_with_virtual_primary
  desktop_virtual_three_monitors
  desktop_virtual_readiness_before_launch
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
  cli_mode_rejected
  cli_unsupported_options
  help_minimal
  game_argv_preserved
  config_mode_selection
  state_target_fields
  rename_repo_namespace_clean
  rename_files_and_identity
  rename_install_paths
  rename_runtime_namespace
  project_structure
)

echo "steam-link-display-adapter wrapper test suite"
echo "package: $PKG_DIR"
echo
# Every test runs in its own subshell: no environment variable, shell global or
# leftover process can leak from one test into the next (spec §10). The parent
# aggregates the per-test results from the captured output.
for t in "${TESTS[@]}"; do
  if [[ -n "$FILTER" && "$t" != *"$FILTER"* ]]; then continue; fi
  _test_log=$(mktemp "${TMPDIR:-/tmp}/slvd-out.XXXXXX")
  _test_sb=$(mktemp "${TMPDIR:-/tmp}/slvd-sb.XXXXXX")
  # The test output goes to a FILE, never through a command substitution pipe:
  # a surviving descendant could keep a pipe open forever and hang the runner.
  # The EXIT trap terminates whatever the test started, on every outcome, and
  # reports the sandbox so the parent can look for leaked processes.
  ( trap 'cleanup_test_processes; printf "%s" "${SANDBOX:-}" >"'"$_test_sb"'"' EXIT; "test_$t" ) >"$_test_log" 2>&1
  cat -- "$_test_log"
  while IFS= read -r _line; do
    case "$_line" in
      ok\ *) PASS=$((PASS + 1)) ;;
      FAIL\ *) FAIL=$((FAIL + 1)); FAILED+=("$t :: ${_line#FAIL }") ;;
    esac
  done <"$_test_log"

  # Leak detection: anything still running that belongs to this test's sandbox.
  _sandbox=$(cat "$_test_sb" 2>/dev/null || true)
  if [[ -n "$_sandbox" ]]; then
    _leaked=$(ps -eo pid=,ppid=,args= 2>/dev/null | grep -F -- "$_sandbox" | grep -v '[g]rep -F' || true)
    if [[ -n "$_leaked" ]]; then
      printf 'PROCESS LEAK DETECTED after %s\n%s\n' "$t" "$_leaked"
      FAIL=$((FAIL + 1)); FAILED+=("$t :: PROCESS LEAK DETECTED")
    fi
  fi
  rm -f "$_test_log" "$_test_sb"
done
echo
echo "== PASS=$PASS FAIL=$FAIL =="
if (( FAIL > 0 )); then
  printf 'failed:\n'
  printf '  %s\n' "${FAILED[@]}"
  printf '\n(re-run a single test with: bash tests/run-tests.sh <name>)\n' 
  exit 1
fi
exit 0
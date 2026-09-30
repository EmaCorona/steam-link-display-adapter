#!/usr/bin/env bash
# Focused unit/contract tests for the real lib/ modules.
#
# The existing tests/run-tests.sh remains the integration/regression suite.
# This file isolates module behavior with the project's command stubs and
# temporary filesystem state, without changing production code.
set -u

TEST_DIR=$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
LIB_ROOT="$PROJECT_ROOT/lib"
STUBS="$PROJECT_ROOT/tests/stubs"
BASE_PATH="$PATH"

PASS=0
FAIL=0
SANDBOX=
RC=0

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail_test() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

eq() {
  local d=$1 a=$2 b=$3
  if [[ "$a" == "$b" ]]; then pass "$d"; else fail_test "$d (got '$a', want '$b')"; fi
}
success() {
  local d=$1 rc=$2
  if (( rc == 0 )); then pass "$d"; else fail_test "$d (exit=$rc)"; fi
}
failure() {
  local d=$1 rc=$2
  if (( rc != 0 )); then pass "$d"; else fail_test "$d (expected non-zero)"; fi
}
has() {
  local d=$1 f=$2 p=$3
  if [[ -f "$f" ]] && grep -q -- "$p" "$f"; then pass "$d"; else fail_test "$d (missing '$p')"; fi
}
absent() {
  local d=$1 p=$2
  if [[ ! -e "$p" ]]; then pass "$d"; else fail_test "$d ($p exists)"; fi
}

fixture_begin() {
  SANDBOX=$(mktemp -d "/tmp/slvd-unit.XXXXXX")
  export HOME="$SANDBOX/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_STATE_HOME="$HOME/.local/state"
  export STUB_STATE_DIR="$SANDBOX/stub"
  export DISPLAY=:99
  export GAMESCOPE_DISPLAY=:99
  export GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
  export XWAYLAND_EXTRA_DISPLAYS=:98
  export XWAYLAND_SCAN_MAX=9
  export PATH="$STUBS:$BASE_PATH"

  unset STUB_SET_DIRTY_NOOP STUB_SET_DIRTY_FAIL STUB_SLEEP_FAIL STUB_WAKE_FAIL
  unset STUB_ALLOW_FAIL STUB_CONNECTOR STUB_NO_INFO STUB_REPICK_REFRESH
  unset STUB_STREAM_ACTIVE STUB_XWL_FAIL STUB_XWL_NOOP STUB_XWL1_ABSENT STUB_KSCREEN_AVAILABLE STUB_KSCREEN_CONNECTOR STUB_KSCREEN_MODE_LIST STUB_KSCREEN_CURRENT_MODE STUB_KSCREEN_FAIL
  unset DRM_MODES_GLOB
  unset HOST_CONNECTOR HOST_ORIGINAL_MODE HOST_ORIGINAL_XWAYLAND_MODE HOST_DESCRIPTION ACTIVE_CONNECTOR DISPLAY_BACKEND
  unset CLIENT_WIDTH CLIENT_HEIGHT CLIENT_FPS
  unset TARGET_WIDTH TARGET_HEIGHT TARGET_REFRESH TARGET_FPS TARGET_SOURCE TARGET_MODE_SPEC
  unset LOCAL_WIDTH LOCAL_HEIGHT LOCAL_REFRESH

  CONNECTOR=auto
  STREAM_WIDTH=1920
  STREAM_HEIGHT=1200
  STREAM_REFRESH=60
  STREAM_FPS=60
  STREAM_ASPECT=16:10
  STREAM_ALT_REFRESHES=
  STREAM_MODE=auto
  STREAM_CAPTURE_HINT_MAX_AGE_SECONDS=10
  STREAM_NO_COMPATIBLE_FALLBACK=auto
  STREAM_ASPECT_TOLERANCE=5
  STREAM_DETECT_WINDOW_SECONDS=180
  STREAM_DETECT_WAIT_SECONDS=1
  STREAM_XWAYLAND_SERVER_INDEX=1
  STREAM_XWAYLAND_ALLOW_SUPERRES=0
  MODE_TIMEOUT_SECONDS=1
  POLL_INTERVAL_SECONDS=0.01

  STATE_DIR="$SANDBOX/state"
  CONFIG_DIR="$SANDBOX/config"
  LOG_FILE="$SANDBOX/wrapper.log"
  STATE_FILE="$STATE_DIR/state"
  LOCK_FILE="$STATE_DIR/lock"
  MODES_FILE="$SANDBOX/gamescope/modes.cfg"
  MODES_BACKUP="$STATE_DIR/modes.cfg.backup"
  STEAM_STREAM_LOG="$SANDBOX/steam.log"
  STEAM_STREAM_LOG_PREV="$SANDBOX/steam.previous.log"

  mkdir -p "$STATE_DIR" "$CONFIG_DIR" "$(dirname -- "$MODES_FILE")" "$STUB_STATE_DIR"
  printf 'StubMake StubModel:3440x1440@165 0\n' >"$MODES_FILE"
  printf '3440x1440@165\n' >"$STUB_STATE_DIR/mode"
  printf '3440x1440\n' >"$STUB_STATE_DIR/xwl1_mode"
  printf 'drm: selecting mode 3440x1440@165Hz\n' >"$STUB_STATE_DIR/journal"
  : >"$STUB_STATE_DIR/dynamic.log"
  : >"$STUB_STATE_DIR/sleep.log"
  : >"$STEAM_STREAM_LOG"
  : >"$STEAM_STREAM_LOG_PREV"
  export STUB_CONNECTOR=DP-3
  export STUB_MODE_LIST='3440x1440@165 1920x1200@60'
  export STUB_STREAM_ACTIVE=1
  export LIB_ROOT
}

fixture_end() {
  if [[ -n "$SANDBOX" && -d "$SANDBOX" ]]; then rm -rf "$SANDBOX"; fi
  SANDBOX=
}

load_lib() {
  # shellcheck disable=SC1090
  source "$LIB_ROOT/core/bootstrap.sh"
  # validate_config lives in workflow.sh; source only for its direct contract.
  # shellcheck disable=SC1090
  source "$LIB_ROOT/core/workflow.sh"
}

run_expected() {
  RC=0
  "$@" >/dev/null 2>&1 || RC=$?
  return 0
}

write_host() {
  local connector=$1 mode=$2 modes=$3
  export STUB_CONNECTOR="$connector"
  export STUB_MODE_LIST="$modes"
  printf '%s\n' "$mode" >"$STUB_STATE_DIR/mode"
  printf 'drm: selecting mode %sHz\n' "$mode" >"$STUB_STATE_DIR/journal"
  printf '%s\n' "$mode" | cut -d@ -f1 >"$STUB_STATE_DIR/xwl1_mode"
  printf 'StubMake StubModel:%s 0\n' "$mode" >"$MODES_FILE"
}

steam_hint() {
  local file=$1 age=$2 text=$3 stamp
  stamp=$(date -d "@$(($(date +%s) - age))" '+%Y-%m-%d %H:%M:%S')
  printf '[%s][293.94] %s\n' "$stamp" "$text" >>"$file"
}

test_display_and_connector() {
  fixture_begin
  eq "mode_geometry strips refresh" "$(mode_geometry '1920x1080@144')" '1920x1080'
  eq "mode_geometry preserves plain geometry" "$(mode_geometry '1920x1080')" '1920x1080'
  eq "mode_width parses width" "$(mode_width '2560x1440@165')" '2560'
  eq "mode_height parses height" "$(mode_height '2560x1440@165')" '1440'
  eq "mode_refresh parses refresh" "$(mode_refresh '2560x1440@165')" '165'
  eq "mode_refresh is empty without refresh" "$(mode_refresh '2560x1440')" ''

  export STUB_MODE_LIST='1920x1200@60 1920x1080@60 invalid 1920x1080@bad 1920x1200@60'
  eq "Gamescope mode list filters invalid and duplicates" "$(get_host_mode_list)" $'1920x1080@60\n1920x1200@60'

  export STUB_MODE_LIST=
  rm -f "$MODES_FILE"
  mkdir -p "$SANDBOX/drm"
  printf '2560x1440\n1920x1080\n' >"$SANDBOX/drm/modes"
  export DRM_MODES_GLOB="$SANDBOX/drm/modes"
  eq "kernel ModeDB is fallback source" "$(get_host_mode_list)" $'2560x1440\n1920x1080'

  ACTIVE_CONNECTOR=HDMI-A-1
  eq "kernel glob follows runtime connector" "$(drm_modes_default_glob)" '/sys/class/drm/card*-HDMI-A-1/modes'
  fixture_end
}

test_resolution() {
  fixture_begin
  export STUB_MODE_LIST='3440x1440@165 1920x1200@60 1920x1080@60'
  eq "exact resolution is preferred" "$(resolve_target_mode 1920 1080 60)" '1920 1080 60'
  eq "aspect-compatible 16:10 beats 16:9" "$(resolve_target_mode 1280 800 60)" '1920 1200 60'
  eq "16:9 client keeps 16:9 geometry" "$(resolve_target_mode 1920 1080 60)" '1920 1080 60'

  export STUB_MODE_LIST='1280x800@60 1280x800@90'
  eq "client FPS chooses sufficient refresh" "$(resolve_target_mode 1280 800 89)" '1280 800 90'

  export STUB_MODE_LIST='1920x1080@60 1920x1080@120'
  eq "higher refresh wins after equivalent score" "$(resolve_target_mode 1920 1080 60)" '1920 1080 120'

  export STUB_MODE_LIST='1050x1000@60'
  eq "five percent aspect boundary is accepted" "$(resolve_target_mode 1000 1000 60)" '1050 1000 60'

  export STUB_MODE_LIST='1051x1000@60'
  run_expected resolve_target_mode 1000 1000 60
  failure "aspect outside tolerance is rejected" "$RC"

  export STUB_MODE_LIST='1920x1080 invalid 1920x1080@bad'
  eq "invalid host modes are ignored" "$(resolve_target_mode 1920 1080 60)" '1920 1080 '

  export STUB_MODE_LIST='3440x1440@165 1920x1200@60'
  run_expected resolve_target_mode 2560 1440 60
  failure "no compatible host mode fails closed" "$RC"
  fixture_end
}

test_detection() {
  fixture_begin
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1920x1200 60.00 FPS'
  eq "fresh hint is parsed" "$(get_latest_stream_capture_hint)" '1920 1200 60'

  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1280x800 89.49 FPS'
  eq "FPS .49 rounds down" "$(get_latest_stream_capture_hint)" '1280 800 89'
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: 1280x800 89.50 FPS'
  eq "FPS .50 rounds up" "$(get_latest_stream_capture_hint)" '1280 800 90'

  : >"$STEAM_STREAM_LOG"
  steam_hint "$STEAM_STREAM_LOG" 30 'Maximum capture: 1920x1200 60.00 FPS'
  steam_hint "$STEAM_STREAM_LOG_PREV" 1 'Maximum capture: 1280x800 90.00 FPS'
  eq "previous log supplies fresh hint" "$(get_latest_stream_capture_hint)" '1280 800 90'

  : >"$STEAM_STREAM_LOG"
  : >"$STEAM_STREAM_LOG_PREV"
  steam_hint "$STEAM_STREAM_LOG" 60 'Maximum capture: 1920x1200 60.00 FPS'
  run_expected get_latest_stream_capture_hint
  failure "stale hint is rejected" "$RC"

  : >"$STEAM_STREAM_LOG"
  steam_hint "$STEAM_STREAM_LOG" 1 'Maximum capture: malformed'
  run_expected get_latest_stream_capture_hint
  failure "malformed hint is rejected" "$RC"

  export STUB_STREAM_ACTIVE=1
  run_expected _sl_streaming_signals_present
  success "current streaming sink is detected" "$RC"

  unset STUB_STREAM_ACTIVE
  run_expected _sl_streaming_signals_present
  failure "missing streaming sink is not detected" "$RC"

  # Force the pw-cli fallback by shadowing pactl with a command that returns no sink.
  local pw_bin="$SANDBOX/pw-only"
  mkdir -p "$pw_bin"
  cp "$STUBS/pw-cli" "$pw_bin/pw-cli"
  cat >"$pw_bin/pactl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$pw_bin/pactl" "$pw_bin/pw-cli"
  PATH="$pw_bin:$STUBS:$BASE_PATH" STUB_STREAM_ACTIVE=1 run_expected _sl_streaming_signals_present
  success "pw-cli fallback is detected independently" "$RC"

  # Deterministic event test: the local pactl double creates the sink when
  # subscribe starts, avoiding arbitrary sleep-based races.
  local event_bin="$SANDBOX/event-bin"
  mkdir -p "$event_bin"
  cat >"$event_bin/pactl" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "${1:-} ${2:-} ${3:-}" == "list short sinks" ]]; then
  if [[ -f "$STUB_STATE_DIR/stream-on" ]]; then
    printf '42	steam-streaming-playback	PipeWire	SUSPENDED
'
  fi
  exit 0
fi
if [[ "$1" == subscribe ]]; then
  : >"$STUB_STATE_DIR/stream-on"
  printf "Event 'new' on sink #42
"
  exit 0
fi
exit 0
EOF
  chmod +x "$event_bin/pactl"
  rm -f "$STUB_STATE_DIR/stream-on"
  PATH="$event_bin:$STUBS:$BASE_PATH" STUB_STREAM_ACTIVE=0 run_expected steam_link_streaming_active
  success "event-driven detection catches a new sink deterministically" "$RC"
  fixture_end
}

test_profile_and_state() {
  fixture_begin
  DISPLAY_BACKEND=gamescope
  write_host HDMI-A-1 '2560x1440@144' '2560x1440@144 1920x1080@60'
  if capture_host_profile; then RC=0; else RC=$?; fi
  success "host profile captures the active connector" "$RC"
  eq "host connector is runtime value" "$HOST_CONNECTOR" 'HDMI-A-1'
  eq "host original mode is runtime value" "$HOST_ORIGINAL_MODE" '2560x1440@144'
  eq "host original Xwayland geometry is captured" "$HOST_ORIGINAL_XWAYLAND_MODE" '2560x1440'

  unset HOST_ORIGINAL_MODE
  printf 'ORIGINAL_MODE=3840x2160@120
' >"$STATE_FILE"
  eq "restore prefers saved profile" "$(original_mode_for_restore)" '3840x2160@120'

  rm -f "$STATE_FILE"
  export LOCAL_WIDTH=3440 LOCAL_HEIGHT=1440 LOCAL_REFRESH=165
  eq "legacy restore fallback remains available" "$(original_mode_for_restore)" '3440x1440@165'

  unset HOST_ORIGINAL_XWAYLAND_MODE
  printf 'ORIGINAL_XWAYLAND_MODE=3840x2160
' >"$STATE_FILE"
  eq "Xwayland restore prefers saved profile" "$(original_xwayland_mode_for_restore)" '3840x2160'

  : >"$STUB_STATE_DIR/journal"
  unset HOST_ORIGINAL_MODE HOST_ORIGINAL_XWAYLAND_MODE LOCAL_WIDTH LOCAL_HEIGHT LOCAL_REFRESH
  run_expected capture_host_profile
  failure "profile capture fails without current host mode" "$RC"

  write_host DP-3 '3440x1440@165' '3440x1440@165'
  unset XWAYLAND_DISPLAY_CACHE
  declare -gA XWAYLAND_DISPLAY_CACHE=()
  export STUB_XWL1_ABSENT=1
  if capture_host_profile; then RC=0; else RC=$?; fi
  success "profile capture tolerates absent Xwayland server" "$RC"
  eq "absent original Xwayland geometry is empty" "$HOST_ORIGINAL_XWAYLAND_MODE" ''

  DISPLAY_BACKEND=desktop
  HOST_CONNECTOR=DP-2
  HOST_ORIGINAL_MODE=3440x1440@165
  HOST_ORIGINAL_XWAYLAND_MODE=3440x1440
  HOST_DESCRIPTION='StubMake StubModel'
  CLIENT_WIDTH=1920
  CLIENT_HEIGHT=1200
  CLIENT_FPS=60
  TARGET_WIDTH=1920
  TARGET_HEIGHT=1200
  TARGET_REFRESH=60
  TARGET_FPS=60
  TARGET_SOURCE=steam_capture_hint
  TARGET_MODE_SPEC=auto
  XWAYLAND_SYNCED=1
  MODES_EXISTED=1
  SCREEN_SLEEP_REQUESTED=1
  state_write STREAMING
  has "state persists selected backend" "$STATE_FILE" 'DISPLAY_BACKEND=desktop'
  has "state persists original connector" "$STATE_FILE" 'ORIGINAL_CONNECTOR=DP-2'
  has "state persists original mode" "$STATE_FILE" 'ORIGINAL_MODE=3440x1440@165'
  has "state persists original Xwayland" "$STATE_FILE" 'ORIGINAL_XWAYLAND_MODE=3440x1440'
  has "state persists target source" "$STATE_FILE" 'TARGET_SOURCE=steam_capture_hint'
  state_clear
  absent "state_clear removes state file" "$STATE_FILE"
  fixture_end
}

test_xwayland() {
  fixture_begin
  unset XWAYLAND_DISPLAY_CACHE
  declare -gA XWAYLAND_DISPLAY_CACHE=()

  eq "server #1 maps by Gamescope server id" "$(xwayland_display_for_server 1)" ':98'
  eq "server #0 maps by Gamescope server id" "$(xwayland_display_for_server 0)" ':99'

  run_expected xwayland_server_present 1
  success "known Xwayland server is detected" "$RC"
  run_expected xwayland_server_present 7
  failure "unknown Xwayland server is rejected" "$RC"

  TARGET_WIDTH=1920
  TARGET_HEIGHT=1200
  TARGET_REFRESH=60
  run_expected set_stream_xwayland_mode
  success "stream geometry is applied to Xwayland #1" "$RC"
  eq "Xwayland #1 receives target geometry" "$(cat "$STUB_STATE_DIR/xwl1_mode")" '1920x1200'

  run_expected verify_stream_xwayland_mode
  success "stream Xwayland geometry verifies" "$RC"

  if restore_stream_xwayland_mode '3440x1440'; then RC=0; else RC=$?; fi
  success "Xwayland restore accepts explicit geometry" "$RC"
  eq "Xwayland restore uses supplied geometry" "$(cat "$STUB_STATE_DIR/xwl1_mode")" '3440x1440'

  if restore_stream_xwayland_mode ''; then RC=0; else RC=$?; fi
  eq "missing restore geometry returns status 2" "$RC" '2'

  unset XWAYLAND_DISPLAY_CACHE
  declare -gA XWAYLAND_DISPLAY_CACHE=()
  export STUB_XWL1_ABSENT=1
  if restore_stream_xwayland_mode '2560x1440'; then RC=0; else RC=$?; fi
  success "restore is a no-op when Xwayland #1 is absent" "$RC"
  fixture_end
}

test_snapshot() {
  fixture_begin
  printf 'Model A:3440x1440@165 0
Other:1920x1080@60 0
' >"$MODES_FILE"
  MODES_EXISTED=0
  BACKUP_TAKEN=0
  backup_modes_file
  eq "existing modes.cfg is backed up exactly" "$(cat "$MODES_BACKUP")" "$(cat "$MODES_FILE")"
  eq "existing-file flag is preserved" "$MODES_EXISTED" '1'
  eq "backup ownership flag is set" "$BACKUP_TAKEN" '1'
  restore_modes_file
  eq "existing modes.cfg restores exactly" "$(cat "$MODES_FILE")" $'Model A:3440x1440@165 0\nOther:1920x1080@60 0'

  rm -f "$MODES_FILE" "$MODES_BACKUP"
  MODES_EXISTED=0
  backup_modes_file
  eq "missing modes.cfg produces empty snapshot" "$(cat "$MODES_BACKUP")" ''
  eq "missing-file flag is preserved" "$MODES_EXISTED" '0'
  restore_modes_file
  absent "missing original modes.cfg remains absent" "$MODES_FILE"

  printf 'Model A:3440x1440@165 0
Model A:1920x1080@60 0
Other:1280x800@60 0
' >"$MODES_FILE"
  write_saved_mode_for_description 'Model A' 1920 1200 60
  eq "duplicate description is collapsed" "$(grep -c '^Model A:' "$MODES_FILE")" '1'
  has "saved target geometry is present" "$MODES_FILE" 'Model A:1920x1200@60'
  has "unrelated description is preserved" "$MODES_FILE" 'Other:1280x800@60 0'
  write_saved_mode_for_description 'New Model' 1280 800 60
  has "new description is appended" "$MODES_FILE" 'New Model:1280x800@60'
  fixture_end
}


test_desktop_backend() {
  fixture_begin
  export STUB_NO_INFO=1 STUB_KSCREEN_AVAILABLE=1 STUB_KSCREEN_CONNECTOR=DP-3
  export STUB_KSCREEN_MODE_LIST='3440x1440@165 1920x1200@60'
  unset DISPLAY_BACKEND
  run_expected display_backend_detect
  success "Desktop backend is detected without Gamescope" "$RC"
  eq "Desktop backend name" "$DISPLAY_BACKEND" 'desktop'
  eq "Desktop connector discovery" "$(desktop_get_connector_name)" 'DP-3'
  eq "Desktop current mode discovery" "$(desktop_get_current_mode)" '3440x1440@165'
  eq "Desktop mode list" "$(desktop_get_host_mode_list)" $'1920x1200@60\n3440x1440@165'
  TARGET_WIDTH=1920 TARGET_HEIGHT=1200 TARGET_REFRESH=60
  run_expected desktop_apply_target_mode
  success "Desktop target mode applies and verifies" "$RC"
  eq "Desktop target is active" "$(desktop_get_current_mode)" '1920x1200@60'
  HOST_ORIGINAL_MODE='3440x1440@165'
  run_expected desktop_restore_host_state
  success "Desktop host mode restores" "$RC"
  eq "Desktop original mode is active" "$(desktop_get_current_mode)" '3440x1440@165'
  fixture_end
}

test_validation_system_logging() {
  fixture_begin

  if validate_config; then RC=0; else RC=$?; fi
  success "default configuration is valid" "$RC"

  STREAM_MODE=invalid
  if validate_config; then RC=0; else RC=$?; fi
  failure "invalid STREAM_MODE is rejected" "$RC"
  STREAM_MODE=auto

  STREAM_WIDTH=0
  if validate_config; then RC=0; else RC=$?; fi
  failure "zero width is rejected" "$RC"
  STREAM_WIDTH=1920

  STREAM_HEIGHT=1200
  STREAM_ASPECT=21:9
  if validate_config; then RC=0; else RC=$?; fi
  failure "aspect mismatch is rejected" "$RC"
  STREAM_ASPECT=16:10

  CONNECTOR='bad connector'
  if validate_config; then RC=0; else RC=$?; fi
  failure "invalid connector characters are rejected" "$RC"
  CONNECTOR=auto

  STREAM_NO_COMPATIBLE_FALLBACK=maybe
  if validate_config; then RC=0; else RC=$?; fi
  failure "invalid fallback policy is rejected" "$RC"
  STREAM_NO_COMPATIBLE_FALLBACK=auto

  STREAM_XWAYLAND_ALLOW_SUPERRES=2
  if validate_config; then RC=0; else RC=$?; fi
  failure "invalid Xwayland flag is rejected" "$RC"
  STREAM_XWAYLAND_ALLOW_SUPERRES=0

  run_expected require_cmd bash
  success "require_cmd accepts available dependency" "$RC"
  run_expected require_cmd command-that-does-not-exist
  failure "require_cmd rejects missing dependency" "$RC"

  log 'unit log entry'
  has "log writes to configured LOG_FILE" "$LOG_FILE" 'unit log entry'

  LOCK_FILE="$SANDBOX/lock"
  if lock_acquire; then RC=0; else RC=$?; fi
  success "lock acquisition succeeds" "$RC"
  run_expected flock -n "$LOCK_FILE" -c true
  failure "second process is blocked by held lock" "$RC"
  flock -u 9
  exec 9>&-

  fixture_end
}

load_lib

printf 'steam-link-display-adapter unit test suite\n\n'

printf '%s\n' '--- display/connector ---'
test_display_and_connector
printf '\n'

printf '%s\n' '--- resolution ---'
test_resolution
printf '\n'

printf '%s\n' '--- detection ---'
test_detection
printf '\n'

printf '%s\n' '--- profile/state ---'
test_profile_and_state
printf '\n'

printf '%s\n' '--- xwayland ---'
test_xwayland
printf '\n'

printf '%s\n' '--- snapshot ---'
test_snapshot
printf '\n'

printf '%s\n' '--- desktop backend ---'
test_desktop_backend
printf '\n'

printf '%s\n' '--- config/system/logging ---'
test_validation_system_logging
printf '\n'

printf 'UNIT TESTS: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then exit 0; fi
exit 1

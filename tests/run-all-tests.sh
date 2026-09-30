#!/usr/bin/env bash
# Full deterministic test entrypoint: unit contracts + integration regressions.
set -u
TEST_DIR=$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd)
FILTER=${1:-}
unit_rc=0
integration_rc=0
bash "$TEST_DIR/unit/run-tests.sh" || unit_rc=$?
bash "$TEST_DIR/run-tests.sh" "$FILTER" || integration_rc=$?
if (( unit_rc == 0 && integration_rc == 0 )); then
  printf '%s\n' 'FULL SUITE: PASS'
  exit 0
fi
printf 'FULL SUITE: FAIL (unit=%s integration=%s)\n' "$unit_rc" "$integration_rc"
exit 1

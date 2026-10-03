#!/bin/bash
# Tests for gate_review_conclude.sh — the review job's last step.
# [savvy-backend#1595 / tracking #1239, ported to savvy_landing] A reviewer
# crash must conclude the job FAILURE (never success), and publish infra_token
# ONLY for infra classes.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../gate_review_conclude.sh"
FAILS=0
[ -f "$SCRIPT" ] || { echo "Error: $SCRIPT not found"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# c DESC WANT_RC WANT_INFRA_TOKEN JOB FLOOR TOKEN
c() {
  local desc="$1" want_rc="$2" want_tok="$3" job="$4" floor="$5" token="$6" rc got
  : > "$TMP/out"
  env -i PATH="$PATH" GITHUB_OUTPUT="$TMP/out" JOB_STATUS="$job" FLOOR_OUTCOME="$floor" ENFORCE_TOKEN="$token" \
    bash "$SCRIPT" >/dev/null 2>&1
  rc=$?
  got="$(sed -n 's/^infra_token=//p' "$TMP/out")"
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want_tok" ]; then echo "PASS: $desc"
  else echo "FAIL: $desc — rc=$rc infra_token='$got' (want rc=$want_rc token='$want_tok')"; FAILS=$((FAILS + 1)); fi
}

c "clean reviewer (PASS) -> success, no infra_token"            0 ""                              success success PASS
for t in AUTH_FAIL PERMISSION_DENIED_INFRA USAGE_CAP_INFRA EMPTY_RESULT_INFRA INSTALLATION_RATE_LIMIT_INFRA NO_EXEC_FILE_INFRA RUNNER_SANDBOX_MISSING_INFRA FAIL_HARD; do
  c "infra token $t -> FAILURE + infra_token=$t" 1 "$t" success success "$t"
done
c "ROUTE_HUMAN -> FAILURE, NO infra_token (stays a floor block)"  1 ""  success success ROUTE_HUMAN
c "empty token (enforce step never ran) -> FAILURE, no token"     1 ""  success success ""
c "unknown token -> FAILURE, no token"                            1 ""  success success WHATEVER
c "floor_check failed (tier-0/CI-surface) -> FAILURE, never an infra token even if one is set" 1 "" failure failure NO_EXEC_FILE_INFRA
c "PASS token but another step failed (job.status=failure) -> FAILURE" 1 "" failure success PASS
c "PASS token but floor_check not success -> FAILURE"              1 ""  success skipped PASS
c "lookalike token NO_EXEC_FILE_INFRA_X -> FAILURE, no token"     1 ""  success success NO_EXEC_FILE_INFRA_X

# No GITHUB_OUTPUT at all must not crash the script (it just cannot publish).
env -i PATH="$PATH" JOB_STATUS=success FLOOR_OUTCOME=success ENFORCE_TOKEN=NO_EXEC_FILE_INFRA bash "$SCRIPT" >/dev/null 2>&1
if [ $? = 1 ]; then echo "PASS: no GITHUB_OUTPUT -> still FAILURE"; else echo "FAIL: no GITHUB_OUTPUT -> not FAILURE"; FAILS=$((FAILS + 1)); fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

#!/bin/bash
# Matrix test for gate_binding_verdict.sh — the opus-gate job's binding verdict.
# [savvy-backend#1595 / tracking #1239, ported to savvy_landing] A reviewer
# crash must read as a non-pass; the ONLY success-class output is PASS (this
# repo has no by-design skip class, so there is no NOT_REQUIRED:* output).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../gate_binding_verdict.sh"
FAILS=0

[ -f "$SCRIPT" ] || { echo "Error: $SCRIPT not found"; exit 1; }

# v DESC WANT [VAR=VALUE ...] — run the script with exactly the given inputs
# (everything else unset) and compare its single output token.
v() {
  local desc="$1" want="$2" got; shift 2
  got=$(env -i PATH="$PATH" "$@" bash "$SCRIPT")
  if [ "$got" = "$want" ]; then echo "PASS: $desc"; else echo "FAIL: $desc — got '$got', want '$want'"; FAILS=$((FAILS + 1)); fi
}

# A healthy baseline: floor ok, Opus required (tier high), reviewer PASS,
# enforcement success.
OK=(JOB_STATUS=success FLOOR_OUTCOME=success RISK_TIER=high ENFORCE_TOKEN=PASS ENFORCE_VERDICT_OUTCOME=success)
# vw DESC WANT NAME=VALUE... — the baseline with overrides applied.
vw() {
  local desc="$1" want="$2"; shift 2
  local args=() kv k o skip
  for kv in "${OK[@]}"; do
    k="${kv%%=*}"; skip=0
    for o in "$@"; do [ "${o%%=*}" = "$k" ] && skip=1; done
    [ "$skip" = 0 ] && args+=("$kv")
  done
  # ${args[@]+...}: bash 3.2 (macOS) treats an empty array as unbound under set -u.
  v "$desc" "$want" ${args[@]+"${args[@]}"} "$@"
}

echo "--- PASS ---"
vw "reviewer clean + enforcement success + nothing failed -> PASS" PASS

echo "--- every infra token -> INFRA:<TOKEN> ---"
for t in AUTH_FAIL PERMISSION_DENIED_INFRA USAGE_CAP_INFRA EMPTY_RESULT_INFRA INSTALLATION_RATE_LIMIT_INFRA INSTALLATION_REST_THROTTLE_INFRA NO_EXEC_FILE_INFRA RUNNER_SANDBOX_MISSING_INFRA FAIL_HARD; do
  vw "token $t -> INFRA:$t" "INFRA:$t" ENFORCE_TOKEN="$t" ENFORCE_VERDICT_OUTCOME=skipped
done
vw "#1595 replay: NO_EXEC_FILE_INFRA, verdict step skipped, job 'success' (infra arms exit 0) -> INFRA, not PASS" \
  "INFRA:NO_EXEC_FILE_INFRA" ENFORCE_TOKEN=NO_EXEC_FILE_INFRA ENFORCE_VERDICT_OUTCOME=skipped JOB_STATUS=success

echo "--- ROUTE_HUMAN / FLOOR / FAIL ---"
vw "reviewer ran but needs a human -> ROUTE_HUMAN" ROUTE_HUMAN ENFORCE_TOKEN=ROUTE_HUMAN ENFORCE_VERDICT_OUTCOME=skipped
vw "floor_check failed (tier-0 / CI-surface / review failure) -> FLOOR" FLOOR FLOOR_OUTCOME=failure RISK_TIER= ENFORCE_TOKEN= ENFORCE_VERDICT_OUTCOME= JOB_STATUS=failure
vw "floor_check skipped/cancelled -> FAIL (unknown, never a pass)" FAIL FLOOR_OUTCOME=skipped
vw "floor_check output missing entirely -> FAIL" FAIL FLOOR_OUTCOME=
vw "Opus said FAIL (Enforce Opus verdict failed) -> FAIL" FAIL ENFORCE_VERDICT_OUTCOME=failure JOB_STATUS=failure
vw "token PASS but the verdict step did not run -> FAIL" FAIL ENFORCE_VERDICT_OUTCOME=skipped
vw "token PASS, verdict step ok, but ANOTHER step failed (job.status=failure) -> FAIL" FAIL JOB_STATUS=failure
vw "job cancelled -> FAIL" FAIL JOB_STATUS=cancelled
vw "enforce token empty (step never ran) -> FAIL" FAIL ENFORCE_TOKEN= ENFORCE_VERDICT_OUTCOME=skipped
vw "unknown enforce token -> FAIL" FAIL ENFORCE_TOKEN=SOMETHING_NEW ENFORCE_VERDICT_OUTCOME=skipped
vw "token with a lookalike infra substring -> FAIL, not INFRA" FAIL ENFORCE_TOKEN="NO_EXEC_FILE_INFRA_EXTRA" ENFORCE_VERDICT_OUTCOME=skipped

echo "--- Opus not required: there is no by-design skip in this repo ---"
vw "risk tier empty (risk-tier step failed/skipped) -> FAIL" FAIL RISK_TIER= ENFORCE_TOKEN= ENFORCE_VERDICT_OUTCOME=skipped
vw "risk tier 'docs' (the retired skip) -> FAIL, docs-only does not pass free" FAIL RISK_TIER=docs ENFORCE_TOKEN= ENFORCE_VERDICT_OUTCOME=skipped
vw "risk tier unknown value -> FAIL" FAIL RISK_TIER=low ENFORCE_TOKEN= ENFORCE_VERDICT_OUTCOME=skipped
vw "tier docs even with a PASS token and a successful verdict step -> FAIL (never a free pass)" FAIL RISK_TIER=docs

echo "--- no input at all ---"
v "nothing set -> FAIL" FAIL

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

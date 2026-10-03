#!/usr/bin/env bash
# gate_review_conclude.sh — the review (Sonnet, Tier 1) job's FINAL step.
# Exit 0 only when the reviewer ran clean; exit 1 otherwise. Also publishes
# `infra_token` (to $GITHUB_OUTPUT) when the reviewer failed because it could
# not RUN, so opus-gate's floor can tell an infra crash from a real block.
#
# [savvy-backend#1595 / tracking #1239 — ported to savvy_landing] Every infra
# arm of "Enforce review actually ran" exits 0 by design ("so the check doesn't
# sit permanently red"), so a reviewer crash concluded the review job SUCCESS
# and downstream gates read it as a clean Tier 1. This step makes the crash
# visible as a FAILURE. It does not change what the arms do (labels, comments,
# tracking-issue append): it only stops the job from concluding success
# afterwards.
#
# Why exit 1 rather than neutral: GitHub Actions jobs cannot conclude neutral,
# and neutral/skipped count as PASSING for required checks.
#
# Why infra_token exists: opus-gate's floor treats `review=failure` as a hard
# block (the "closes the skipped-green footgun" rule). With review now failing
# on a crash, that rule would turn every reviewer outage into an unfixable
# FLOOR block and Opus (the binding decider) would never run. opus-gate
# exempts a review failure ONLY when this output names an infra class.
# ROUTE_HUMAN (incomplete review / workflow edit), a tier-0 failure and
# anything unrecognised leave infra_token EMPTY and remain a floor block.
#
# savvy_landing has no triage job, so unlike the backend copy there is no
# trivial-PR success path: the only success is a clean reviewer (PASS).
#
# Env (all from GitHub's own contexts or literals this repo writes):
#   JOB_STATUS      job.status  ('success' only if no non-continue-on-error step failed)
#   FLOOR_OUTCOME   steps.floor_check.conclusion
#   ENFORCE_TOKEN   steps.enforce_review_ran.outputs.token (gate_check_ran.py)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gate_binding_verdict.sh
source "$SCRIPT_DIR/gate_binding_verdict.sh"   # INFRA_TOKENS: one list, two consumers

JOB_STATUS="${JOB_STATUS:-}"
FLOOR_OUTCOME="${FLOOR_OUTCOME:-}"
TOKEN="${ENFORCE_TOKEN:-}"

emit_infra_token() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "infra_token=$1" >> "$GITHUB_OUTPUT"; fi
}

if [ "$FLOOR_OUTCOME" = "success" ] && [ "$JOB_STATUS" = "success" ] && [ "$TOKEN" = "PASS" ]; then
  echo "review: reviewer ran clean (PASS); concluding success."
  exit 0
fi

if [ "$FLOOR_OUTCOME" = "success" ] && [ -n "$TOKEN" ] && [[ "$INFRA_TOKENS" == *" $TOKEN "* ]]; then
  emit_infra_token "$TOKEN"
  echo "::error::review: reviewer could not run (${TOKEN}) — concluding FAILURE, never success. opus-gate will still run (infra exemption); the binding verdict decides."
else
  echo "::error::review: not a clean Tier-1 pass (token='${TOKEN:-<none>}', floor_check=${FLOOR_OUTCOME:-<none>}, job=${JOB_STATUS:-<none>}) — concluding FAILURE."
fi
exit 1

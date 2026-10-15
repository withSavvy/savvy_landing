#!/usr/bin/env bash
# gate_infra_retry_decide.sh — should the Gate's opus-gate job be re-run once?
# PURE function of env (no network, no clock). Prints exactly ONE line:
#   RETRY            every condition below holds
#   SKIP:<code>      the first condition that failed; ANY empty/malformed input
#                    is a SKIP
#
# WHY [savvy-backend#1537, run 37237626545, 2026-10-04/05] opus-gate crashed on
# INSTALLATION_RATE_LIMIT_INFRA with every other job green; a human ran
# `gh run rerun --failed` ~10 min later and the required `opus-verdict-recorded`
# status flipped to success. gate_infra_retry.sh automates that re-run and calls
# this script before and after its wait.
#
# GUARANTEE (G1-G5 here; G6, self-hosted runners only, is the workflow's):
#   G1 only the three self-clearing tokens below, on THIS run's newest status
#   G2 at most one retry per head SHA (any run on the SHA at attempt 2+ blocks)
#   G3 never FLOOR / FAIL / ROUTE_HUMAN / other infra tokens / human override
#   G4 never after the PR moved: closed, head changed, base not the default
#      branch, or a newer Gate run for the SHA
#   G5 (orchestrator) the only write is POST actions/jobs/<opus-gate job>/rerun
# FAIL-SAFE: any doubt means no retry, which is today's behaviour. Every check is
# exact equality or an anchored regex, never a prefix or substring match.
#
# Inputs (env or plain shell variables; sourcing only defines the function):
#   workflow_run event   RUN_EVENT RUN_CONCLUSION RUN_ATTEMPT RUN_ID RUN_HEAD_SHA
#                        RUN_PR_NUMBERS (space-separated)
#   gathered live        OPUS_JOB_ID OPUS_JOB_CONCLUSION STATUS_STATE STATUS_CREATOR
#                        STATUS_TARGET_URL STATUS_DESC EXPECTED_TARGET_URL PR_STATE
#                        PR_HEAD_SHA PR_BASE_REF DEFAULT_BRANCH SHA_NEWEST_RUN_ID
#                        SHA_MAX_ATTEMPT
set -uo pipefail

# What post_opus_verdict_recorded.sh writes for an INFRA verdict (sync-tested).
INFRA_DESC_PREFIX="opus-gate infra-neutral ("

# Only tokens that clear with TIME: a spent installation REST budget, a usage cap.
# NOT retried: AUTH_FAIL, PERMISSION_DENIED_INFRA, RUNNER_SANDBOX_MISSING_INFRA,
# NO_EXEC_FILE_INFRA, EMPTY_RESULT_INFRA, FAIL_HARD (credentials/permissions/runner
# are broken; waiting fixes nothing and a re-run burns another Opus attempt) and
# FLOOR / FAIL / ROUTE_HUMAN (a rejection or a human route, not infra). Must stay a
# subset of gate_binding_verdict.sh's INFRA_TOKENS (tested).
RETRYABLE_INFRA_TOKENS=" INSTALLATION_RATE_LIMIT_INFRA INSTALLATION_REST_THROTTLE_INFRA USAGE_CAP_INFRA "

gate_infra_retry_decide() {
  local num_re='^[0-9]+$' sha_re='^[0-9a-f]{40}$' IFS=' ' token matched=false

  [ "${RUN_EVENT:-}" = "pull_request" ] || { echo "SKIP:not_pull_request"; return 0; }
  [ "${RUN_CONCLUSION:-}" = "failure" ] || { echo "SKIP:not_failure"; return 0; }
  [ "${RUN_ATTEMPT:-}" = "1" ] || { echo "SKIP:not_first_attempt"; return 0; }
  [[ "${RUN_ID:-}" =~ $num_re ]] || { echo "SKIP:bad_run_id"; return 0; }
  [[ "${RUN_HEAD_SHA:-}" =~ $sha_re ]] || { echo "SKIP:bad_head_sha"; return 0; }
  # exactly one PR: the whole value is one number (fork PRs arrive empty)
  [[ "${RUN_PR_NUMBERS:-}" =~ $num_re ]] || { echo "SKIP:pr_count"; return 0; }

  [[ "${OPUS_JOB_ID:-}" =~ $num_re ]] || { echo "SKIP:opus_job_missing"; return 0; }
  [ "${OPUS_JOB_CONCLUSION:-}" = "failure" ] || { echo "SKIP:opus_not_failed"; return 0; }

  [ -n "${STATUS_STATE:-}" ] || { echo "SKIP:status_missing"; return 0; }
  [ "${STATUS_CREATOR:-}" = "github-actions[bot]" ] || { echo "SKIP:status_not_from_actions"; return 0; }
  if [ -z "${STATUS_TARGET_URL:-}" ] || [ "${STATUS_TARGET_URL:-}" != "${EXPECTED_TARGET_URL:-}" ]; then
    echo "SKIP:status_other_run"; return 0
  fi
  [ "${STATUS_STATE:-}" = "failure" ] || { echo "SKIP:status_not_failure"; return 0; }
  for token in $RETRYABLE_INFRA_TOKENS; do
    [ "${STATUS_DESC:-}" = "${INFRA_DESC_PREFIX}${token})" ] && matched=true
  done
  [ "$matched" = "true" ] || { echo "SKIP:token_not_retryable"; return 0; }

  [ "${PR_STATE:-}" = "open" ] || { echo "SKIP:pr_not_open"; return 0; }
  [ "${PR_HEAD_SHA:-}" = "$RUN_HEAD_SHA" ] || { echo "SKIP:head_moved"; return 0; }
  if [ -z "${PR_BASE_REF:-}" ] || [ "$PR_BASE_REF" != "${DEFAULT_BRANCH:-}" ]; then
    echo "SKIP:base_not_default"; return 0
  fi

  [ "${SHA_NEWEST_RUN_ID:-}" = "$RUN_ID" ] || { echo "SKIP:newer_run"; return 0; }
  [ "${SHA_MAX_ATTEMPT:-}" = "1" ] || { echo "SKIP:already_retried"; return 0; }
  echo "RETRY"
}

# Allow `source` (tests, the orchestrator) as well as direct execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then gate_infra_retry_decide; fi

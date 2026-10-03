#!/usr/bin/env bash
# gate_binding_verdict.sh — the opus-gate job's BINDING verdict, as a pure
# function of structural step results. Prints exactly ONE token:
#
#   PASS                  Opus ran, the reviewer ran clean, "Enforce Opus
#                         verdict" succeeded, and no other step failed.
#   INFRA:<TOKEN>         the reviewer could not run (gate_check_ran.py token:
#                         AUTH_FAIL, PERMISSION_DENIED_INFRA, USAGE_CAP_INFRA,
#                         EMPTY_RESULT_INFRA, INSTALLATION_RATE_LIMIT_INFRA,
#                         INSTALLATION_REST_THROTTLE_INFRA, NO_EXEC_FILE_INFRA,
#                         RUNNER_SANDBOX_MISSING_INFRA, FAIL_HARD). A crash is NOT a pass and NOT a rejection.
#   ROUTE_HUMAN           the reviewer ran but needs a human (incomplete review).
#   FLOOR                 hard-block floor tripped (tier-0 failure, CI-surface
#                         edit, review failure that is not an infra crash).
#   FAIL                  everything else: Opus said FAIL, no verdict, a failed
#                         enforcement step, Opus not run, or ANY missing/unknown
#                         input.
#
# Ported from savvy-backend's gate_binding_verdict.sh (savvy-backend#1595 /
# tracking #1239). savvy_landing differs in ONE way: it has no triage/`trivial`
# class and no opus_decide step, so there is NO by-design skip and therefore no
# NOT_REQUIRED:* output. Its docs-only risk tier no longer skips Opus either
# (the risk-tier step now always reports `high`; see gate.yml), so a missing or
# non-`high` RISK_TIER can only mean the classification step itself failed,
# which is FAIL.
#
# WHY THIS EXISTS [savvy-backend#1595, tracking #1239]
# The opus-gate JOB used to conclude `success` on every infra arm (each
# `exit 0` by design, "so the check does not sit permanently red"). opus-gate is
# not a required check, so none of it stopped a merge: #1595 was bot-merged at
# 22:29:20Z, four minutes BEFORE its opus-gate crashed (NO_EXEC_FILE_INFRA) and
# concluded `success` at 22:33:51Z. The recorder job in gate.yml turns this
# verdict into the required status `opus-verdict-recorded`; only PASS posts
# success.
#
# FAIL-CLOSED by construction: the only success-class output is reached through
# explicit positive checks, every other path (including empty/unknown inputs)
# ends in FAIL.
#
# Inputs (env; every one comes from GitHub's own steps/needs/job contexts or a
# fixed literal this repo writes — never from review text or PR-controlled
# strings):
#   JOB_STATUS               job.status at the time of the call ('success' only
#                            if NO non-continue-on-error step has failed so far)
#   FLOOR_OUTCOME            steps.floor_check.conclusion
#   RISK_TIER                steps.risk_tier.outputs.tier ('high' = Opus must run)
#   ENFORCE_TOKEN            steps.enforce_opus_ran.outputs.token
#   ENFORCE_VERDICT_OUTCOME  steps.enforce_verdict.outcome
set -uo pipefail

# Tokens that mean "the reviewer could not run" (couldn't verify, not a code
# rejection). Keep in sync with gate_check_ran.py and gate_review_conclude.sh
# (which sources this file for the list).
INFRA_TOKENS=" AUTH_FAIL PERMISSION_DENIED_INFRA USAGE_CAP_INFRA EMPTY_RESULT_INFRA INSTALLATION_RATE_LIMIT_INFRA INSTALLATION_REST_THROTTLE_INFRA NO_EXEC_FILE_INFRA RUNNER_SANDBOX_MISSING_INFRA FAIL_HARD "

binding_verdict() {
  local job_status="${JOB_STATUS:-}"
  local floor="${FLOOR_OUTCOME:-}"
  local tier="${RISK_TIER:-}"
  local token="${ENFORCE_TOKEN:-}"
  local verdict_outcome="${ENFORCE_VERDICT_OUTCOME:-}"

  # 1. Floor. Anything but a clean floor_check is never a pass. A real failure
  #    is FLOOR; skipped/cancelled/empty is an unknown, hence FAIL.
  if [ "$floor" != "success" ]; then
    if [ "$floor" = "failure" ]; then echo "FLOOR"; else echo "FAIL"; fi
    return 0
  fi

  # 2. Opus must have been required. savvy_landing has no by-design skip class.
  if [ "$tier" != "high" ]; then
    echo "FAIL"
    return 0
  fi

  # 3. The reviewer's own ran-check decides.
  case "$token" in
    PASS) ;;
    ROUTE_HUMAN) echo "ROUTE_HUMAN"; return 0 ;;
    "") echo "FAIL"; return 0 ;;
    *)
      if [[ "$INFRA_TOKENS" == *" $token "* ]]; then
        echo "INFRA:${token}"
      else
        echo "FAIL"
      fi
      return 0
      ;;
  esac

  # 4. Reviewer ran clean. PASS only if the verdict-enforcement step really
  #    succeeded AND no earlier step failed.
  if [ "$verdict_outcome" = "success" ] && [ "$job_status" = "success" ]; then
    echo "PASS"
  else
    echo "FAIL"
  fi
}

# Allow `source` (tests, gate_review_conclude.sh) as well as direct execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  binding_verdict
fi

#!/usr/bin/env bash
# post_opus_verdict_recorded.sh — post the `opus-verdict-recorded` commit
# status on a PR head SHA from opus-gate's binding verdict.
#
# [savvy-backend#1595 / tracking #1239] opus-gate is not a required check and
# its job used to conclude `success` on every crash, so a PR could (and did)
# merge before — or without — a binding Opus verdict. This status is the
# merge-gating signal that closes that: once an admin adds the context
# `opus-verdict-recorded` (app_id 15368) to branch protection, GitHub holds the
# merge at "Expected" until THIS script posts success for the head SHA. It is
# posted with GITHUB_TOKEN (creator github-actions[bot], app 15368) from the
# job-scoped `statuses: write` of gate.yml's `record-opus-verdict` job.
#
# usage: post_opus_verdict_recorded.sh <opus-gate result> <binding_verdict> \
#                                      <actor> <head_sha> [run_url]
# env:   GH_TOKEN (statuses:write), GITHUB_REPOSITORY, optional
#        GATE_RETRY_SLEEP (seconds between gh retries, default 2)
#
# STATE MAPPING — an explicit allowlist; everything else is `failure`:
#   success  result=success AND verdict in {PASS, NOT_REQUIRED:trivial}
#   success  result=skipped AND actor=dependabot[bot]   (opus-gate's own `if:`
#            skips dependabot PRs by design; the deterministic floor still ran)
#   failure  INFRA:<TOKEN>   description "opus-gate infra-neutral (<TOKEN>)"
#            ROUTE_HUMAN / FLOOR / FAIL
#            cancelled, skipped (non-dependabot), failure, empty, unknown
# GitHub treats neutral/skipped as passing for required checks and a job can
# never conclude neutral, so "couldn't verify" is deliberately FAILURE: a
# reviewer crash must never read as success. A missing output, an unknown
# token, or result != success all land on failure, so a future exit-0
# regression elsewhere in gate.yml still cannot pass a merge.
#
# NEVER OVERWRITES A HUMAN OVERRIDE: if the newest `opus-verdict-recorded`
# status on this SHA is a success from github-actions[bot] whose description
# starts with `human-override` (posted by auto-arm-merge.yml's
# record-human-opus-override after verify_human_approved.sh), this script
# leaves it alone. The override is SHA-bound, so a new push is judged afresh.
#
# Exit 1 only when the POST itself fails after retries: the context is then
# left missing, which is also fail-closed (merge waits on "Expected").
set -uo pipefail

RESULT="${1:-}"
VERDICT="${2:-}"
ACTOR="${3:-}"
HEAD_SHA="${4:-}"
RUN_URL="${5:-}"

CONTEXT="opus-verdict-recorded"
OVERRIDE_PREFIX="human-override"
RETRY_SLEEP="${GATE_RETRY_SLEEP:-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GITHUB_REPOSITORY:-}"

if ! printf '%s' "$HEAD_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "::error::post_opus_verdict_recorded: head sha '${HEAD_SHA}' is not a 40-char hex sha — refusing to post."
  exit 1
fi
if [ -z "$REPO" ]; then
  echo "::error::post_opus_verdict_recorded: GITHUB_REPOSITORY is unset."
  exit 1
fi

# --- decide state + description (pure; no network) -------------------------
STATE="failure"
DESC="opus-gate produced no binding verdict"

if [ "$RESULT" = "success" ] && { [ "$VERDICT" = "PASS" ] || [ "$VERDICT" = "NOT_REQUIRED:trivial" ]; }; then
  STATE="success"
  if [ "$VERDICT" = "PASS" ]; then DESC="opus-gate PASS"; else DESC="opus-gate not required (trivial PR)"; fi
elif [ "$RESULT" = "skipped" ] && [ "$ACTOR" = "dependabot[bot]" ]; then
  STATE="success"
  DESC="opus-gate skipped by design (dependabot)"
else
  case "$VERDICT" in
    INFRA:*)
      TOKEN="${VERDICT#INFRA:}"
      # The token is one of our own fixed gate_check_ran.py names; refuse to
      # echo anything else into a status description.
      if printf '%s' "$TOKEN" | grep -Eq '^[A-Z_]{1,60}$'; then
        DESC="opus-gate infra-neutral (${TOKEN})"
      else
        DESC="opus-gate infra-neutral (unrecognised token)"
      fi
      ;;
    ROUTE_HUMAN) DESC="opus-gate routed to human review (no binding verdict)" ;;
    FLOOR)       DESC="opus-gate floor block (needs human review)" ;;
    FAIL)        DESC="opus-gate verdict FAIL / no verdict" ;;
    *)
      case "$RESULT" in
        cancelled) DESC="opus-gate cancelled - re-run required" ;;
        skipped)   DESC="opus-gate skipped - no binding verdict" ;;
        success)   DESC="opus-gate succeeded without a recognised verdict" ;;
        *)         DESC="opus-gate produced no binding verdict" ;;
      esac
      ;;
  esac
fi
# GitHub caps a status description at 140 characters.
DESC="$(printf '%s' "$DESC" | cut -c1-140)"

# --- never clobber a human override on this SHA ------------------------------
LATEST=""
if LATEST_RAW="$(bash "$SCRIPT_DIR/gh_retry.sh" --retries 2 --sleep "$RETRY_SLEEP" -- \
      gh api "repos/${REPO}/commits/${HEAD_SHA}/statuses?per_page=100" \
      --jq "[.[] | select(.context==\"${CONTEXT}\")][0] | if . == null then \"\" else \"\\(.state)|\\(.creator.login)|\\(.description)\" end" 2>/dev/null)"; then
  LATEST="$(printf '%s\n' "$LATEST_RAW" | tail -n1)"
else
  # Fail-closed bias: proceed to post. Worst case a rare API blip drops a
  # human override, which fails CLOSED (the human re-adds the label).
  echo "::warning::post_opus_verdict_recorded: could not read existing ${CONTEXT} statuses on ${HEAD_SHA:0:7}; posting without the override check."
fi
case "$LATEST" in
  "success|github-actions[bot]|${OVERRIDE_PREFIX}"*)
    echo "${CONTEXT} on ${HEAD_SHA:0:7} is a human override (${LATEST#*|*|}) — leaving it in place (computed: ${STATE}, ${DESC})."
    exit 0
    ;;
esac

# --- post ---------------------------------------------------------------------
ARGS=(-f "state=${STATE}" -f "context=${CONTEXT}" -f "description=${DESC}")
case "$RUN_URL" in
  https://*) ARGS+=(-f "target_url=${RUN_URL}") ;;
esac

if ! bash "$SCRIPT_DIR/gh_retry.sh" --retries 2 --sleep "$RETRY_SLEEP" -- \
     gh api -X POST "repos/${REPO}/statuses/${HEAD_SHA}" "${ARGS[@]}" >/dev/null; then
  echo "::error::post_opus_verdict_recorded: could not POST ${CONTEXT}=${STATE} for ${HEAD_SHA:0:7} after retries. The context stays missing/stale (merge waits on Expected). Re-run the failed jobs."
  exit 1
fi
echo "Posted ${CONTEXT}=${STATE} for ${HEAD_SHA:0:7}: ${DESC}"
if [ "$STATE" = "failure" ]; then
  echo "::warning::${CONTEXT}=failure — ${DESC}. To merge: re-run failed jobs once the cause clears, or have an allowlisted human add 'human-approved' (SHA-bound override)."
fi
exit 0

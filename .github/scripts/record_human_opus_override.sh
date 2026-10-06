#!/usr/bin/env bash
# record_human_opus_override.sh — mint the `opus-verdict-recorded` HUMAN
# OVERRIDE status when an allowlisted human adds `human-approved`.
#
# [savvy-backend#1595 / tracking #1239] The binding status is
# `opus-verdict-recorded`, posted by gate.yml's record-opus-verdict job. When
# the reviewer cannot run (crash, usage cap, rate limit) or a human has
# reviewed the PR themselves, the escape hatch is a SHA-bound override, never
# label removal ("removing labels never releases").
#
# Runs from auto-arm-merge.yml's record-human-opus-override job under the
# pull_request_target event, from a BASE-ref checkout (never the PR head), with
# job-scoped statuses:write and GITHUB_TOKEN, so the status creator is
# github-actions[bot] (app 15368) — the only creator branch protection will
# accept once the context is made required.
#
# Gates, ALL of which must hold or nothing is posted:
#   1. the event is `labeled` with label `human-approved`;
#   2. verify_human_approved.sh: the NEWEST `human-approved` labeled event was
#      made by an allowlisted, non-bot human (TIER_B_RELEASE_ACTORS), verified
#      live via the issue-events API, fail-closed on any API error;
#   3. the PR is STILL labeled human-approved (a label added then removed is
#      not an approval);
#   4. the PR's live head SHA equals the head SHA of the triggering event
#      (SHA-bound: a push after the label needs a fresh approval).
#
# Env: GH_TOKEN (statuses:write), GITHUB_REPOSITORY, PR_NUMBER, EVENT_HEAD_SHA,
#      EVENT_ACTION, EVENT_LABEL_NAME, TIER_B_RELEASE_ACTORS,
#      GATE_RETRY_SLEEP (default 2). Every value is passed via env, never
#      interpolated into the workflow's run: line.
# Exit: 0 posted OR a gate above said no (a no is not an error); 1 when a gate
#       could not be evaluated or the POST failed (loud, nothing released).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT="opus-verdict-recorded"
OVERRIDE_PREFIX="human-override"
RETRY_SLEEP="${GATE_RETRY_SLEEP:-2}"
REPO="${GITHUB_REPOSITORY:-}"
PR="${PR_NUMBER:-}"
EVENT_SHA="${EVENT_HEAD_SHA:-}"

if [ "${EVENT_ACTION:-}" != "labeled" ] || [ "${EVENT_LABEL_NAME:-}" != "human-approved" ]; then
  echo "record_human_opus_override: event '${EVENT_ACTION:-}' / label '${EVENT_LABEL_NAME:-}' is not 'labeled human-approved' — nothing to do."
  exit 0
fi
if ! printf '%s' "$PR" | grep -Eq '^[0-9]+$' || [ -z "$REPO" ]; then
  echo "::error::record_human_opus_override: PR_NUMBER '${PR}' / GITHUB_REPOSITORY '${REPO}' invalid."
  exit 1
fi
if ! printf '%s' "$EVENT_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "::error::record_human_opus_override: event head sha is not a 40-char hex sha."
  exit 1
fi

# shellcheck source=verify_human_approved.sh
source "$SCRIPT_DIR/verify_human_approved.sh"
export PR_NUMBER="$PR"
if ! verified_human_approved_adder; then
  echo "'human-approved' was not verifiably added by an allowlisted human — NO override recorded. (Removing labels never releases; re-run the gate or have an allowlisted human add the label.)"
  exit 0
fi
ADDER="$HUMAN_APPROVED_ADDER"
# GitHub logins are [A-Za-z0-9-]; anything else never reaches a description.
if ! printf '%s' "$ADDER" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$'; then
  echo "::error::record_human_opus_override: verified adder '${ADDER}' is not a plain GitHub login — refusing to record."
  exit 1
fi

# Gates 3 + 4 from ONE live read of the PR: line 1 is the head sha, the rest
# are the label names (gh's built-in --jq; no jq binary needed on the runner).
if ! PR_LIVE="$(bash "$SCRIPT_DIR/gh_retry.sh" --retries 2 --sleep "$RETRY_SLEEP" -- \
      gh api "repos/${REPO}/pulls/${PR}" --jq '.head.sha, (.labels[].name)')"; then
  echo "::error::record_human_opus_override: could not read the live PR — refusing to record an override (fail-closed)."
  exit 1
fi
LIVE_SHA="$(printf '%s\n' "$PR_LIVE" | head -n1)"
if [ "$LIVE_SHA" != "$EVENT_SHA" ]; then
  echo "PR head moved since the label event (event ${EVENT_SHA:0:7}, live ${LIVE_SHA:0:7}) — an approval is SHA-bound; NO override recorded for the old or the new commit."
  exit 0
fi
if ! printf '%s\n' "$PR_LIVE" | tail -n +2 | grep -qx 'human-approved'; then
  echo "'human-approved' is no longer on the PR — an approval that was withdrawn is not an override. NO override recorded."
  exit 0
fi

DESC="${OVERRIDE_PREFIX} by ${ADDER} for ${EVENT_SHA:0:7}"
DESC="$(printf '%s' "$DESC" | cut -c1-140)"

post_override() {
  bash "$SCRIPT_DIR/gh_retry.sh" --retries 2 --sleep "$RETRY_SLEEP" -- \
    gh api -X POST "repos/${REPO}/statuses/${EVENT_SHA}" \
      -f state=success -f "context=${CONTEXT}" -f "description=${DESC}" >/dev/null
}

if ! post_override; then
  echo "::error::record_human_opus_override: could not POST the override status for ${EVENT_SHA:0:7} after retries."
  exit 1
fi
echo "Posted ${CONTEXT}=success (${DESC})."

# The gate's recorder can race this job: if it read "no override yet" a moment
# before we posted and then POSTs its failure afterwards, ours is no longer the
# newest status. Re-check once and re-post. (The recorder itself skips when it
# sees an override, so this only covers the sub-second interleave.)
NEWEST="$(bash "$SCRIPT_DIR/gh_retry.sh" --retries 1 --sleep "$RETRY_SLEEP" -- \
  gh api "repos/${REPO}/commits/${EVENT_SHA}/statuses?per_page=100" \
  --jq "[.[] | select(.context==\"${CONTEXT}\")][0].description // \"\"" 2>/dev/null | tail -n1 || true)"
case "$NEWEST" in
  "${OVERRIDE_PREFIX}"*) ;;
  *)
    echo "::warning::record_human_opus_override: a later ${CONTEXT} status overtook the override ('${NEWEST}') — re-posting once."
    post_override || { echo "::error::record_human_opus_override: re-post failed."; exit 1; }
    ;;
esac
exit 0

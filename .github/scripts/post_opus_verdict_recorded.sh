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
# env:   GH_TOKEN (statuses:write + pull-requests:read + issues:read),
#        GITHUB_REPOSITORY,
#        PR_NUMBER (required: the FLOOR re-derives the file list),
#        BASE_REF + DEFAULT_BRANCH (required: a status is minted ONLY for a PR
#        into the default branch, see below),
#        PR_UPDATED_AT + TIER_B_RELEASE_ACTORS (re-verify a human override),
#        optional GATE_RETRY_SLEEP (seconds between gh retries, default 2)
#
# DEFAULT-BRANCH ONLY [2026-10-02 review fix, savvy-backend#1595]: commit
# statuses belong to the SHA, not to the PR, and gate.yml runs for a PR into
# ANY branch except develop. A writer could push branch X (= main plus an edited
# copy of THIS script), open a PR feat->X, and have a recorder that checked out
# X's tip post success on feat's head SHA; a second PR feat->main with the same
# SHA then inherits it. So (1) gate.yml checks this script out from the DEFAULT
# branch, never github.base_ref, and (2) this script posts NOTHING unless
# BASE_REF equals DEFAULT_BRANCH. Residual (documented in gate.yml): a side
# branch whose own gate.yml is edited can still post a status on a SHA.
#
# STATE MAPPING — an explicit allowlist; everything else is `failure`:
#   failure  FLOOR (checked FIRST, regardless of every upstream input): the
#            recorder RE-DERIVES the PR's changed files ITSELF from the GitHub
#            API (never from an event payload or an upstream job output) and, if
#            ANY path (a rename's previous_filename included) matches the
#            CI-surface regex (ci_surface_paths.sh), posts
#            "FLOOR: CI-surface change — human release required". PASS,
#            NOT_REQUIRED:trivial and the dependabot-by-design skip can never
#            apply to a CI-surface PR. Fail-CLOSED: an API error, an empty list,
#            a missing PR number or a list at the API's 3000-file cap is also
#            failure. Only the SHA-bound `human-approved` override (below) can
#            turn it green. [2026-10-02, savvy-backend#1595 / #1239]
#   success  result=success AND verdict in {PASS, NOT_REQUIRED:trivial}
#   success  result=skipped AND actor=dependabot[bot] (and, by the FLOOR above,
#            the PR's live file list matches NO CI-surface path). opus-gate's own
#            `if:` skips dependabot PRs by design, but this repo's dependabot.yml
#            has only the `github-actions` ecosystem, so EVERY dependabot PR
#            edits .github/workflows/ — a CI-surface change that must not get a
#            free pass: those post the FLOOR failure.
#   failure  INFRA:<TOKEN>   description "opus-gate infra-neutral (<TOKEN>)"
#            ROUTE_HUMAN / FLOOR / FAIL
#            cancelled, skipped (non-dependabot), failure, empty, unknown
# GitHub treats neutral/skipped as passing for required checks and a job can
# never conclude neutral, so "couldn't verify" is deliberately FAILURE: a
# reviewer crash must never read as success. A missing output, an unknown
# token, or result != success all land on failure, so a future exit-0
# regression elsewhere in gate.yml still cannot pass a merge.
#
# NEVER OVERWRITES A *VERIFIED* HUMAN OVERRIDE: if the newest
# `opus-verdict-recorded` status on this SHA is a success from
# github-actions[bot] whose description starts with `human-override`, this
# script RE-VERIFIES it from live API data before leaving it alone (the
# description is only a hint: every workflow run on any PR that shares the SHA
# posts as github-actions[bot], so a forged "human-override ..." status must not
# become sticky). Verified means ALL of: verify_human_approved.sh (newest
# `human-approved` adder is an allowlisted non-bot human), the label is still on
# the PR, the live head SHA equals this run's HEAD_SHA, and the label was added
# AFTER this run's triggering event (PR_UPDATED_AT), so an approval of an older
# commit never carries over. Anything else (including an API error) means the
# computed verdict is posted over it. [2026-10-02 review fix]
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
LABEL="human-approved"
RETRY_SLEEP="${GATE_RETRY_SLEEP:-2}"
# GET /pulls/{n}/files returns at most 3000 files; a list that long may hide a
# CI-surface path, so it is treated as unreadable (fail-closed).
PR_FILES_API_CAP=3000
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GITHUB_REPOSITORY:-}"
PR="${PR_NUMBER:-}"
BASE="${BASE_REF:-}"
DEFAULT="${DEFAULT_BRANCH:-}"
EVENT_TS="${PR_UPDATED_AT:-}"
# shellcheck source=ci_surface_paths.sh
source "$SCRIPT_DIR/ci_surface_paths.sh"

if ! printf '%s' "$HEAD_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "::error::post_opus_verdict_recorded: head sha '${HEAD_SHA}' is not a 40-char hex sha — refusing to post."
  exit 1
fi
if [ -z "$REPO" ]; then
  echo "::error::post_opus_verdict_recorded: GITHUB_REPOSITORY is unset."
  exit 1
fi
# A status is minted only for a PR into the default branch (see the header).
if [ -z "$BASE" ] || [ -z "$DEFAULT" ]; then
  echo "::error::post_opus_verdict_recorded: BASE_REF ('${BASE}') or DEFAULT_BRANCH ('${DEFAULT}') is unset — refusing to post (fail-closed)."
  exit 1
fi
if [ "$BASE" != "$DEFAULT" ]; then
  echo "post_opus_verdict_recorded: PR base '${BASE}' is not the default branch '${DEFAULT}' — posting NO ${CONTEXT} status (statuses are SHA-global; one is minted only for a PR into the default branch)."
  exit 0
fi

# --- re-derive the CI-surface floor from the API (never from upstream) --------
# PR files, one per line, prefixed `F:` (filename) / `P:` (previous_filename of
# a rename, so moving a file OUT of the CI surface is still a CI-surface change).
FLOOR_DESC=""
fetch_pr_files() {
  printf '%s' "$PR" | grep -Eq '^[0-9]+$' || return 1
  bash "$SCRIPT_DIR/gh_retry.sh" --retries 2 --sleep "$RETRY_SLEEP" -- \
    gh api --paginate "repos/${REPO}/pulls/${PR}/files?per_page=100" \
    --jq '.[] | ("F:" + .filename), (if .previous_filename then "P:" + .previous_filename else empty end)' 2>/dev/null
}
if PR_FILES="$(fetch_pr_files)"; then
  FILE_COUNT="$(printf '%s\n' "$PR_FILES" | grep -c '^F:' || true)"
  if [ "${FILE_COUNT:-0}" -eq 0 ]; then
    FLOOR_DESC="FLOOR: could not read PR files (empty list) — human release required"
  elif [ "$FILE_COUNT" -ge "$PR_FILES_API_CAP" ]; then
    FLOOR_DESC="FLOOR: PR file list truncated at the API cap — human release required"
  elif printf '%s\n' "$PR_FILES" | sed 's/^[FP]://' | grep -Eq "$CI_SURFACE_REGEX"; then
    FLOOR_DESC="FLOOR: CI-surface change — human release required"
  fi
else
  FLOOR_DESC="FLOOR: could not read PR files — human release required"
fi

# --- decide state + description (pure; no further network) -----------------
STATE="failure"
DESC="opus-gate produced no binding verdict"

if [ -n "$FLOOR_DESC" ]; then
  DESC="$FLOOR_DESC"
elif [ "$RESULT" = "success" ] && { [ "$VERDICT" = "PASS" ] || [ "$VERDICT" = "NOT_REQUIRED:trivial" ]; }; then
  STATE="success"
  if [ "$VERDICT" = "PASS" ]; then DESC="opus-gate PASS"; else DESC="opus-gate not required (trivial PR)"; fi
elif [ "$RESULT" = "skipped" ] && [ "$ACTOR" = "dependabot[bot]" ]; then
  STATE="success"
  DESC="opus-gate skipped by design (dependabot, no CI-surface paths)"
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

# --- never clobber a VERIFIED human override on this SHA ---------------------
# stamp_digits TS — `2026-10-02T01:02:03Z` -> 20261002010203 (empty if malformed),
# so two timestamps compare as plain integers (no GNU/BSD date dependency).
stamp_digits() {
  printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || return 1
  printf '%s' "$1" | tr -d -c '0-9'
}

# override_is_verified — re-derive the human override from live API data. The
# status description is NOT trusted (see the header). Returns 0 only if every
# gate holds; every failure path is "not verified" (fail-closed: the computed
# verdict is posted over the status).
override_is_verified() {
  local live live_sha label_ts label_n event_n
  # 1. the newest human-approved adder is an allowlisted, non-bot human.
  # shellcheck source=verify_human_approved.sh
  source "$SCRIPT_DIR/verify_human_approved.sh"
  export PR_NUMBER="$PR"
  verified_human_approved_adder || return 1
  # 2. the label is still on the PR and the live head is the SHA we judge.
  live="$(bash "$SCRIPT_DIR/gh_retry.sh" --retries 2 --sleep "$RETRY_SLEEP" -- \
        gh api "repos/${REPO}/pulls/${PR}" --jq '.head.sha, (.labels[].name)' 2>/dev/null)" || return 1
  live_sha="$(printf '%s\n' "$live" | head -n1)"
  [ "$live_sha" = "$HEAD_SHA" ] || return 1
  printf '%s\n' "$live" | tail -n +2 | grep -qx "$LABEL" || return 1
  # 3. the approval is newer than this run's triggering event, so approving an
  #    older commit does not carry over to this one.
  label_ts="$(bash "$SCRIPT_DIR/gh_retry.sh" --retries 2 --sleep "$RETRY_SLEEP" -- \
        gh api --paginate "repos/${REPO}/issues/${PR}/events?per_page=100" \
        --jq ".[] | select(.event==\"labeled\" and .label.name==\"${LABEL}\") | .created_at" 2>/dev/null | tail -n1)" || return 1
  label_n="$(stamp_digits "$label_ts")" || return 1
  event_n="$(stamp_digits "$EVENT_TS")" || return 1
  [ "$label_n" -gt "$event_n" ]
}

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
    if override_is_verified; then
      echo "${CONTEXT} on ${HEAD_SHA:0:7} is a VERIFIED human override (${LATEST#*|*|}) — leaving it in place (computed: ${STATE}, ${DESC})."
      exit 0
    fi
    echo "::warning::post_opus_verdict_recorded: ${CONTEXT} on ${HEAD_SHA:0:7} claims a human override (${LATEST#*|*|}) but it does not verify against live data (no allowlisted human-approved adder, label gone, head moved, or approval older than this run) — posting the computed verdict over it."
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

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
# env:   GH_TOKEN (statuses:write + pull-requests:read), GITHUB_REPOSITORY,
#        PR_NUMBER (required: the base check and the FLOOR read the live PR),
#        optional GATE_RETRY_SLEEP (seconds between gh retries, default 2)
#
# DEFAULT-BRANCH ONLY [2026-10-02, savvy-backend#1595]: a status is minted ONLY
# for a PR whose LIVE base (API, not the event payload) is the repo's default
# branch. Statuses belong to the SHA, not the PR, and gate.yml runs for a PR into
# any branch except develop. The job `if:` has the same guard; this re-checks it
# live and fails CLOSED (exit 1, nothing posted) when either read fails.
#
# STATE MAPPING — an explicit allowlist; everything else is `failure`:
#   failure  FLOOR (decided FIRST, whatever every upstream input says): the
#            recorder RE-DERIVES the changed files ITSELF from the API (paginated;
#            a rename's previous_filename included) and, if ANY path matches the
#            CI-surface regex (ci_surface_paths.sh), posts
#            "FLOOR: CI-surface change — human release required". PASS, a
#            by-design skip and a dependabot skip can never green a CI-surface
#            PR (e.g. one that edits only .github/scripts/). Fail-CLOSED: an API
#            error, an empty list or a list shorter than the PR's changed_files
#            (API cap) is also failure. Only the SHA-bound `human-approved`
#            override (below) can turn it green.
#   success  result=success AND verdict=PASS (a real Opus PASS on this head SHA)
#   success  result=success AND verdict=NOT_REQUIRED:trivial, or result=skipped
#            AND actor=dependabot[bot] — the by-design passes, ONLY while the
#            PR's changed_files count is <= TRIVIAL_MAX_FILES (100). Past that the
#            files list is truncated in several APIs, so the PR is not "trivial"
#            and a by-design pass without an Opus review is refused (failure).
#            This repo's dependabot.yml has only the `github-actions` ecosystem,
#            so every dependabot PR edits .github/workflows/ and hits the FLOOR.
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
# More changed files than this and the PR is not "trivial": gh's `files` list and
# friends truncate at 100, so no by-design (no-Opus) pass may apply.
TRIVIAL_MAX_FILES=100
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GITHUB_REPOSITORY:-}"
PR="${PR_NUMBER:-}"
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
if ! printf '%s' "$PR" | grep -Eq '^[0-9]+$'; then
  echo "::error::post_opus_verdict_recorded: PR_NUMBER '${PR}' is not numeric — refusing to post (fail-closed)."
  exit 1
fi

# gh_api_lines ARGS... — gh api through gh_retry (stdout only; errors stay on stderr).
gh_api_lines() {
  bash "$SCRIPT_DIR/gh_retry.sh" --retries 2 --sleep "$RETRY_SLEEP" -- gh api "$@" 2>/dev/null
}

# --- live base guard: mint a status only for a PR into the default branch -----
if ! PR_LIVE="$(gh_api_lines "repos/${REPO}/pulls/${PR}" --jq '.base.ref, .changed_files')" \
   || ! DEFAULT_BRANCH="$(gh_api_lines "repos/${REPO}" --jq '.default_branch' | tail -n1)"; then
  echo "::error::post_opus_verdict_recorded: could not read the live PR / repo — refusing to post (fail-closed)."
  exit 1
fi
BASE_REF="$(printf '%s\n' "$PR_LIVE" | head -n1)"
CHANGED_FILES="$(printf '%s\n' "$PR_LIVE" | sed -n '2p')"
if [ -z "$BASE_REF" ] || [ -z "$DEFAULT_BRANCH" ] || ! printf '%s' "$CHANGED_FILES" | grep -Eq '^[0-9]+$'; then
  echo "::error::post_opus_verdict_recorded: live PR base ('${BASE_REF}'), default branch ('${DEFAULT_BRANCH}') or changed_files ('${CHANGED_FILES}') unreadable — refusing to post (fail-closed)."
  exit 1
fi
if [ "$BASE_REF" != "$DEFAULT_BRANCH" ]; then
  echo "post_opus_verdict_recorded: PR base '${BASE_REF}' is not the default branch '${DEFAULT_BRANCH}' — posting NO ${CONTEXT} status (statuses are SHA-global)."
  exit 0
fi

# --- re-derive the CI-surface floor from the API (never from upstream) --------
# `F:<filename>` per file, plus `P:<previous_filename>` for a rename, so moving a
# file OUT of the CI surface is still a CI-surface change.
FLOOR_DESC=""
if PR_FILES="$(gh_api_lines --paginate "repos/${REPO}/pulls/${PR}/files?per_page=100" \
     --jq '.[] | ("F:" + .filename), (if .previous_filename then "P:" + .previous_filename else empty end)')"; then
  FILE_COUNT="$(printf '%s\n' "$PR_FILES" | grep -c '^F:' || true)"
  if [ "${FILE_COUNT:-0}" -eq 0 ]; then
    FLOOR_DESC="FLOOR: could not read PR files (empty list) — human release required"
  elif [ "$FILE_COUNT" -lt "$CHANGED_FILES" ]; then
    FLOOR_DESC="FLOOR: PR file list truncated by the API — human release required"
  elif printf '%s\n' "$PR_FILES" | sed 's/^[FP]://' | grep -Eq "$CI_SURFACE_REGEX"; then
    FLOOR_DESC="FLOOR: CI-surface change — human release required"
  fi
else
  FLOOR_DESC="FLOOR: could not read PR files — human release required"
fi

# --- decide state + description (pure; no further network) --------------------
STATE="failure"
DESC="opus-gate produced no binding verdict"
BY_DESIGN=""   # the two passes that skip Opus: a trivial PR or a dependabot skip
if { [ "$RESULT" = "success" ] && [ "$VERDICT" = "NOT_REQUIRED:trivial" ]; } || \
   { [ "$RESULT" = "skipped" ] && [ "$ACTOR" = "dependabot[bot]" ]; }; then
  BY_DESIGN=1
fi

if [ -n "$FLOOR_DESC" ]; then
  DESC="$FLOOR_DESC"
elif [ "$RESULT" = "success" ] && [ "$VERDICT" = "PASS" ]; then
  STATE="success"; DESC="opus-gate PASS"
elif [ -n "$BY_DESIGN" ] && [ "$CHANGED_FILES" -gt "$TRIVIAL_MAX_FILES" ]; then
  DESC="no Opus review and ${CHANGED_FILES} changed files (>${TRIVIAL_MAX_FILES}): not trivial"
elif [ -n "$BY_DESIGN" ]; then
  STATE="success"
  if [ "$RESULT" = "skipped" ]; then DESC="opus-gate skipped by design (dependabot, no CI-surface paths)"
  else DESC="opus-gate not required (trivial PR)"; fi
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

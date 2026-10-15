#!/usr/bin/env bash
# gate_infra_retry.sh — re-run a Gate run's opus-gate job ONCE when it failed on
# a self-clearing infra token (rate limit / usage cap), ~10 min after the run.
#
# [savvy-backend#1537, run 37237626545, 2026-10-04/05] The manual fix was
# `gh run rerun <id> --failed` once the installation's REST budget refilled. This
# automates that through the JOB endpoint, so exactly opus-gate (+ its dependent
# `record opus verdict`) runs again; never the whole run.
#
# FLOW  gather -> decide -> sleep -> gather AGAIN -> decide -> one POST
#   * every read goes through gh_retry.sh; a read that fails leaves its inputs
#     EMPTY and gate_infra_retry_decide.sh turns empty into SKIP, so an API error
#     can only mean "no retry" (today's behaviour);
#   * gather resets every input first, so nothing from before the wait survives
#     into the decision that fires the re-run;
#   * the single non-GET call is the POST at the bottom, deliberately NOT wrapped
#     in gh_retry: if the first request reached GitHub and only the response was
#     lost, a retry could request a second re-run.
# It writes no status, label, comment, issue or check and calls no other re-run
# endpoint (frozen by gate-infra-retry-guarantee.test.ts).
#
# env: GH_TOKEN (GITHUB_TOKEN), GITHUB_REPOSITORY, GITHUB_SERVER_URL, and from the
#      workflow_run event RUN_ID RUN_WORKFLOW_ID RUN_EVENT RUN_CONCLUSION
#      RUN_ATTEMPT RUN_HEAD_SHA RUN_PR_NUMBERS; RETRY_DELAY_SECONDS (default 600,
#      max 1200); optional GATE_RETRY_SLEEP (seconds between gh retries, default 2)
# exit: 0 = re-run requested, or any SKIP;  1 = bad configuration, or the POST failed
# shellcheck disable=SC2034  # the gathered inputs are read by the sourced decide function
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gate_infra_retry_decide.sh
source "$SCRIPT_DIR/gate_infra_retry_decide.sh"

MAX_DELAY_SECONDS=1200
GATHER_RETRIES=2
JOB_NAME="opus-gate"
STATUS_CONTEXT="opus-verdict-recorded"
REPO="${GITHUB_REPOSITORY:-}"
DELAY="${RETRY_DELAY_SECONDS:-600}"
RETRY_SLEEP="${GATE_RETRY_SLEEP:-2}"
[[ "$RETRY_SLEEP" =~ ^[0-9]+$ ]] || RETRY_SLEEP=2

fail() { echo "::error::gate-infra-retry: $*"; exit 1; }
# Only [alnum space _().,/-] survives: nothing GitHub-supplied can smuggle a `::`
# workflow command or a newline into the log through a message we print.
log_safe() { printf '%s' "$1" | tr -cd '[:alnum:] _().,/-' | cut -c1-"${2:-100}"; }

# --- validate configuration BEFORE any URL is built or any API call is made ----
{ [[ "$DELAY" =~ ^[0-9]+$ ]] && [ "${#DELAY}" -le 5 ] && [ "$DELAY" -le "$MAX_DELAY_SECONDS" ]; } \
  || fail "RETRY_DELAY_SECONDS must be an integer in 0..${MAX_DELAY_SECONDS} (got '$(log_safe "$DELAY" 20)')"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "GITHUB_REPOSITORY is unset or malformed"
case "${GITHUB_SERVER_URL:-}" in https://*) ;; *) fail "GITHUB_SERVER_URL is unset or not https" ;; esac
[ -n "${GH_TOKEN:-}" ] || fail "GH_TOKEN is unset"
[[ "${RUN_ID:-}" =~ ^[0-9]+$ ]] || fail "RUN_ID is not numeric"
[[ "${RUN_WORKFLOW_ID:-}" =~ ^[0-9]+$ ]] || fail "RUN_WORKFLOW_ID is not numeric"
[[ "${RUN_HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail "RUN_HEAD_SHA is not a 40-char hex sha"

EXPECTED_TARGET_URL="${GITHUB_SERVER_URL}/${REPO}/actions/runs/${RUN_ID}"

# Appended to every read's jq: refuse a field holding a control character (so each
# field is exactly one line), print one field per line, then an END sentinel
# (command substitution strips trailing blank lines; END keeps an empty last
# field countable).
FIELDS_TAIL='| if (map(test("[\\x00-\\x1f]")) | any) then empty else (.[], "END") end'
FIELDS=()

# fetch_fields N API_PATH JQ_ARRAY_EXPR — fills FIELDS with N strings; returns 1
# (FIELDS empty) on an API error or any unexpected shape.
fetch_fields() {
  local n="$1" api_path="$2" expr="$3" raw line i=0
  FIELDS=()
  raw="$(bash "$SCRIPT_DIR/gh_retry.sh" --retries "$GATHER_RETRIES" --sleep "$RETRY_SLEEP" -- \
        gh api "$api_path" --jq "(${expr}) ${FIELDS_TAIL}")" || return 1
  while IFS= read -r line; do FIELDS[i]="$line"; i=$((i + 1)); done <<< "$raw"
  if [ "$i" -ne $((n + 1)) ] || [ "${FIELDS[n]}" != "END" ]; then FIELDS=(); return 1; fi
}

# gather — (re)read every decision input from the live API; a failed read leaves
# its inputs empty.
gather() {
  local pr=""
  OPUS_JOB_ID=""; OPUS_JOB_CONCLUSION=""
  STATUS_STATE=""; STATUS_CREATOR=""; STATUS_TARGET_URL=""; STATUS_DESC=""
  PR_STATE=""; PR_HEAD_SHA=""; PR_BASE_REF=""; DEFAULT_BRANCH=""
  SHA_NEWEST_RUN_ID=""; SHA_MAX_ATTEMPT=""

  # opus-gate of attempt 1: exactly one job by that name.
  if fetch_fields 2 "repos/${REPO}/actions/runs/${RUN_ID}/attempts/1/jobs?per_page=100" \
      "[.jobs[] | select(.name==\"${JOB_NAME}\")] | if length == 1 then [(.[0].id | tostring), (.[0].conclusion // \"\")] else empty end"; then
    OPUS_JOB_ID="${FIELDS[0]}"; OPUS_JOB_CONCLUSION="${FIELDS[1]}"
  else echo "::warning::gate-infra-retry: could not read the ${JOB_NAME} job of run ${RUN_ID}"; fi

  # newest opus-verdict-recorded status on the SHA (the API lists newest first).
  if fetch_fields 4 "repos/${REPO}/commits/${RUN_HEAD_SHA}/statuses?per_page=100" \
      "[.[] | select(.context==\"${STATUS_CONTEXT}\")][0] | if . == null then empty else [(.state // \"\" | tostring), (.creator.login // \"\" | tostring), (.target_url // \"\" | tostring), (.description // \"\" | tostring)] end"; then
    STATUS_STATE="${FIELDS[0]}"; STATUS_CREATOR="${FIELDS[1]}"
    STATUS_TARGET_URL="${FIELDS[2]}"; STATUS_DESC="${FIELDS[3]}"
  else echo "::warning::gate-infra-retry: could not read the ${STATUS_CONTEXT} status on ${RUN_HEAD_SHA:0:7}"; fi

  # the live PR, only when the event named exactly one numeric PR.
  [[ "${RUN_PR_NUMBERS:-}" =~ ^[0-9]+$ ]] && pr="$RUN_PR_NUMBERS"
  if [ -n "$pr" ]; then
    if fetch_fields 4 "repos/${REPO}/pulls/${pr}" \
        '[(.state // "" | tostring), (.head.sha // "" | tostring), (.base.ref // "" | tostring), (.base.repo.default_branch // "" | tostring)]'; then
      PR_STATE="${FIELDS[0]}"; PR_HEAD_SHA="${FIELDS[1]}"
      PR_BASE_REF="${FIELDS[2]}"; DEFAULT_BRANCH="${FIELDS[3]}"
    else echo "::warning::gate-infra-retry: could not read PR #${pr}"; fi
  fi

  # every Gate pull_request run on this SHA: the newest run id, the highest attempt.
  if fetch_fields 2 "repos/${REPO}/actions/workflows/${RUN_WORKFLOW_ID}/runs?head_sha=${RUN_HEAD_SHA}&per_page=100" \
      '[.workflow_runs[] | select(.event == "pull_request")] | if length == 0 then empty else [(map(.id) | max | tostring), (map(.run_attempt) | max | tostring)] end'; then
    SHA_NEWEST_RUN_ID="${FIELDS[0]}"; SHA_MAX_ATTEMPT="${FIELDS[1]}"
  else echo "::warning::gate-infra-retry: could not list the Gate runs for ${RUN_HEAD_SHA:0:7}"; fi
}

# check PHASE — gather, decide, print; returns 0 only for RETRY.
check() {
  local phase="$1" decision note=""
  gather
  decision="$(gate_infra_retry_decide)"
  if [ "$decision" = "RETRY" ]; then
    echo "gate-infra-retry: ${phase}: RETRY (run ${RUN_ID}, ${RUN_HEAD_SHA:0:7}, opus-gate job ${OPUS_JOB_ID})"
    return 0
  fi
  [ -z "$STATUS_DESC" ] || note=" status='$(log_safe "$STATUS_DESC")'"
  echo "::notice::gate-infra-retry: ${phase}: ${decision} (run ${RUN_ID}, ${RUN_HEAD_SHA:0:7}${note}) — not re-running"
  return 1
}

check "first check" || exit 0
echo "gate-infra-retry: waiting ${DELAY}s so the throttle can clear, then re-checking everything."
sleep "$DELAY"
check "re-check after wait" || exit 0

if ! out="$(gh api -X POST "repos/${REPO}/actions/jobs/${OPUS_JOB_ID}/rerun" 2>&1)"; then
  fail "re-run request for ${JOB_NAME} job ${OPUS_JOB_ID} failed: $(log_safe "$out" 300)"
fi
echo "::notice::gate-infra-retry: re-ran ${JOB_NAME} job ${OPUS_JOB_ID} of run ${RUN_ID} (PR #${RUN_PR_NUMBERS}, ${RUN_HEAD_SHA:0:7}); its dependent recorder re-runs with it."

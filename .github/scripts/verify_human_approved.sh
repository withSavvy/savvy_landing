#!/usr/bin/env bash
# verify_human_approved.sh — "did an allowlisted HUMAN add `human-approved`?"
#
# [savvy-backend#1595 / tracking #1239] Extracted from merge-guard.yml's inline
# verified_human_approved_adder() so auto-arm-merge.yml's
# record-human-opus-override job can run the SAME check before it mints the
# binding `opus-verdict-recorded` override status. The function body below is
# byte-identical (modulo indentation) to the one in merge-guard.yml, which keeps
# its inline copy because it has no checkout step;
# __tests__/verify_human_approved.test.sh enforces that. Edit both or neither.
#
# What it checks (all LIVE via the issue-events API, never the triggering
# event payload, for the same stale-payload reason merge-guard's
# read_live_labels() avoids it):
#   * the NEWEST `labeled human-approved` event's actor,
#   * is not a `[bot]` identity (a bot does not assert human review),
#   * is on the TIER_B_RELEASE_ACTORS allowlist (comma/space separated; unset
#     falls back to the repo OWNER login, which matches no real actor, so
#     nothing verifies until the variable is set),
#   * any API/parse failure -> NOT verified (fail-closed).
# KNOWN LIMIT (documented at length in merge-guard.yml): a caller holding the
# allowlisted human's PAT is indistinguishable from that human. This closes
# forgery by other logins and by bots, not a stolen Sara3 credential.
#
# Usage:
#   source .github/scripts/verify_human_approved.sh   # defines the function;
#       verified_human_approved_adder sets HUMAN_APPROVED_ADDER on success
#   bash .github/scripts/verify_human_approved.sh     # exit 0 verified / 1 not;
#       on success prints `adder=<login>` as its last stdout line
# Env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, TIER_B_RELEASE_ACTORS.
HUMAN_APPROVED_ADDER=""

verified_human_approved_adder() {
  local allow raw login login_lc entry
  allow="${TIER_B_RELEASE_ACTORS:-${GITHUB_REPOSITORY%%/*}}"

  if ! raw=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/events" \
               --paginate --jq '.[] | select(.event=="labeled" and .label.name=="human-approved") | .actor.login' 2>&1); then
    echo "::warning::Could not read issue events to verify who added 'human-approved' — treating it as unverifiable (fail-closed): $raw"
    return 1
  fi

  # Multiple 'labeled human-approved' events can exist (label
  # removed and re-added); the newest one is what currently governs,
  # and the events API returns them oldest-first, so the last line
  # is the most recent — same "live, not the triggering snapshot"
  # rule as read_live_labels() above.
  login=$(printf '%s\n' "$raw" | tail -n1)
  if [ -z "$login" ] || [ "$login" = "null" ]; then
    echo "::warning::'human-approved' is present but no matching 'labeled' event was found for it — treating it as unverifiable (fail-closed)."
    return 1
  fi

  login_lc=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')
  case "$login_lc" in
    *"[bot]")
      echo "::warning::'human-approved' was added by '$login', a bot identity — treating it as unverifiable (fail-closed): a bot does not assert human review."
      return 1
      ;;
  esac
  for entry in $(printf '%s' "$allow" | tr ',' ' ' | tr '[:upper:]' '[:lower:]'); do
    if [ "$entry" = "$login_lc" ]; then
      echo "'human-approved' was added by '$login', on the tier-b release allowlist ('$allow')."
      export HUMAN_APPROVED_ADDER="$login"
      return 0
    fi
  done
  echo "::warning::'human-approved' was added by '$login', who is NOT on the tier-b release allowlist ('$allow') — treating it as unverifiable (fail-closed)."
  return 1
}

# Allow `source` (override script, tests) as well as direct execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  if verified_human_approved_adder; then
    echo "adder=${HUMAN_APPROVED_ADDER}"
    exit 0
  fi
  exit 1
fi

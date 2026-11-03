#!/bin/bash
# Table test for gate_infra_retry_decide.sh, the pure "re-run opus-gate once?"
# decision. [savvy-backend#1537, run 37237626545] RETRY only for the three
# self-clearing infra tokens on THIS run's newest failure status of an open,
# unchanged PR with no earlier retry; every other input (including empty or
# malformed) is a SKIP, so any doubt keeps today's no-retry behaviour.
# shellcheck disable=SC2016  # the bash -c programs are literal on purpose
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../gate_infra_retry_decide.sh"
FAILS=0
[ -f "$SCRIPT" ] || { echo "Error: $SCRIPT not found"; exit 1; }

SHA="0123456789abcdef0123456789abcdef01234567"
OTHER_SHA="fedcba9876543210fedcba9876543210fedcba98"
URL="https://github.com/withSavvy/savvy_landing/actions/runs/37237626545"
P="opus-gate infra-neutral ("

# A fully eligible baseline: USAGE_CAP_INFRA failure of run 37237626545.
BASE=(
  RUN_EVENT=pull_request RUN_CONCLUSION=failure RUN_ATTEMPT=1 RUN_ID=37237626545
  "RUN_HEAD_SHA=$SHA" RUN_PR_NUMBERS=1537 OPUS_JOB_ID=99887766 OPUS_JOB_CONCLUSION=failure
  STATUS_STATE=failure "STATUS_CREATOR=github-actions[bot]" "STATUS_TARGET_URL=$URL"
  "STATUS_DESC=${P}USAGE_CAP_INFRA)" "EXPECTED_TARGET_URL=$URL"
  PR_STATE=open "PR_HEAD_SHA=$SHA" PR_BASE_REF=main DEFAULT_BRANCH=main
  SHA_NEWEST_RUN_ID=37237626545 SHA_MAX_ATTEMPT=1
)

eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2', want '$3'"; FAILS=$((FAILS + 1)); fi; }
# d DESC WANT [VAR=VALUE ...] — baseline plus overrides (the later assignment
# wins in `env`), with nothing else in the environment.
d() { local desc="$1" want="$2"; shift 2; eq "$desc" "$(env -i PATH="$PATH" "${BASE[@]}" "$@" bash "$SCRIPT")" "$want"; }
# only DESC WANT [VAR=VALUE ...] — exactly the given inputs.
only() { local desc="$1" want="$2"; shift 2; eq "$desc" "$(env -i PATH="$PATH" "$@" bash "$SCRIPT")" "$want"; }

echo "--- RETRY: exactly the three self-clearing tokens ---"
d "baseline -> RETRY" RETRY
for t in INSTALLATION_RATE_LIMIT_INFRA INSTALLATION_REST_THROTTLE_INFRA USAGE_CAP_INFRA; do
  d "token $t -> RETRY" RETRY "STATUS_DESC=${P}${t})"
done

echo "--- every other description the recorder writes, and near misses -> SKIP:token_not_retryable ---"
for desc in "opus-gate floor block (needs human review)" "opus-gate verdict FAIL / no verdict" \
  "opus-gate routed to human review (no binding verdict)" "FLOOR: CI-surface change — human release required" \
  "opus-gate produced no binding verdict" "opus-gate cancelled - re-run required" "" "*" "${P}.*)" \
  "${P}unrecognised token)" "${P}USAGE_CAP_INFRA) " " ${P}USAGE_CAP_INFRA)" "${P}USAGE_CAP_INFRA) and more" \
  "x ${P}USAGE_CAP_INFRA)" "${P}usage_cap_infra)" "Opus-gate infra-neutral (USAGE_CAP_INFRA)" \
  "${P}USAGE_CAP_INFRA_EXTRA)" "${P}USAGE_CAP_INFRA" "${P}USAGE_CAP_INFRA USAGE_CAP_INFRA)" \
  "${P}USAGE_CAP_INFRA)
x"; do
  d "description '$(printf '%s' "$desc" | tr '\n' '|')'" SKIP:token_not_retryable "STATUS_DESC=$desc"
done
for t in AUTH_FAIL PERMISSION_DENIED_INFRA EMPTY_RESULT_INFRA NO_EXEC_FILE_INFRA RUNNER_SANDBOX_MISSING_INFRA FAIL_HARD; do
  d "infra token $t is not self-clearing" SKIP:token_not_retryable "STATUS_DESC=${P}${t})"
done

echo "--- the status must be this run's, from Actions, and a failure ---"
d "human-override success (this run's url)" SKIP:status_not_failure STATUS_STATE=success "STATUS_DESC=human-override by Sara3"
d "human-override success (another url)" SKIP:status_other_run STATUS_STATE=success "STATUS_TARGET_URL=${URL%?}6" "STATUS_DESC=human-override by Sara3"
d "pending status" SKIP:status_not_failure STATUS_STATE=pending
d "no status at all" SKIP:status_missing STATUS_STATE= STATUS_CREATOR= STATUS_TARGET_URL= STATUS_DESC=
d "status posted by a human/PAT" SKIP:status_not_from_actions STATUS_CREATOR=Sara3
d "lookalike bot" SKIP:status_not_from_actions STATUS_CREATOR=github-actions-bot
d "status from another run" SKIP:status_other_run "STATUS_TARGET_URL=${URL%?}6"
d "status url is a prefix of the expected url" SKIP:status_other_run "STATUS_TARGET_URL=${URL%?}"
d "empty status url" SKIP:status_other_run STATUS_TARGET_URL=
d "empty expected url" SKIP:status_other_run EXPECTED_TARGET_URL=

echo "--- the workflow_run event ---"
d "not a pull_request event" SKIP:not_pull_request RUN_EVENT=push
d "success run" SKIP:not_failure RUN_CONCLUSION=success
d "cancelled run" SKIP:not_failure RUN_CONCLUSION=cancelled
d "attempt 2" SKIP:not_first_attempt RUN_ATTEMPT=2
d "attempt 01" SKIP:not_first_attempt RUN_ATTEMPT=01
d "non-numeric run id" SKIP:bad_run_id RUN_ID=abc
d "run id with a path" SKIP:bad_run_id RUN_ID=123/../x
d "run id with a newline" SKIP:bad_run_id "RUN_ID=12
34"
d "short head sha" SKIP:bad_head_sha RUN_HEAD_SHA=0123456
d "uppercase head sha" SKIP:bad_head_sha "RUN_HEAD_SHA=0123456789ABCDEF0123456789ABCDEF01234567"
d "41-char head sha" SKIP:bad_head_sha "RUN_HEAD_SHA=${SHA}0"
d "no PR (a fork PR has an empty pull_requests list)" SKIP:pr_count RUN_PR_NUMBERS=
d "two PRs on the sha" SKIP:pr_count "RUN_PR_NUMBERS=1537 1538"
d "non-numeric PR" SKIP:pr_count RUN_PR_NUMBERS=abc
d "PR numbers separated by a newline" SKIP:pr_count "RUN_PR_NUMBERS=1537
1538"

echo "--- opus-gate of that run really failed ---"
d "opus job not found" SKIP:opus_job_missing OPUS_JOB_ID=
d "opus job id with a path" SKIP:opus_job_missing "OPUS_JOB_ID=1/rerun"
d "opus job succeeded" SKIP:opus_not_failed OPUS_JOB_CONCLUSION=success
d "opus job conclusion empty" SKIP:opus_not_failed OPUS_JOB_CONCLUSION=

echo "--- the PR has not changed since the failure ---"
d "PR closed" SKIP:pr_not_open PR_STATE=closed
d "PR state unknown" SKIP:pr_not_open PR_STATE=
d "head moved on" SKIP:head_moved "PR_HEAD_SHA=$OTHER_SHA"
d "live head unknown" SKIP:head_moved PR_HEAD_SHA=
d "base is a release branch" SKIP:base_not_default PR_BASE_REF=release
d "base unknown" SKIP:base_not_default PR_BASE_REF=
d "default branch unknown" SKIP:base_not_default DEFAULT_BRANCH=
d "base and default both empty" SKIP:base_not_default PR_BASE_REF= DEFAULT_BRANCH=

echo "--- nothing newer, nothing retried yet ---"
d "a newer Gate run exists for the sha" SKIP:newer_run SHA_NEWEST_RUN_ID=37237626999
d "newest run unknown" SKIP:newer_run SHA_NEWEST_RUN_ID=
d "another run already at attempt 2" SKIP:already_retried SHA_MAX_ATTEMPT=2
d "attempt count unknown" SKIP:already_retried SHA_MAX_ATTEMPT=
d "attempt count 'null'" SKIP:already_retried SHA_MAX_ATTEMPT=null

echo "--- rule order, and missing input is always a SKIP ---"
d "attempt 2 beats a bad token" SKIP:not_first_attempt RUN_ATTEMPT=2 STATUS_DESC=nope
d "bad token beats a closed PR" SKIP:token_not_retryable STATUS_DESC=nope PR_STATE=closed
d "moved head beats a newer run" SKIP:head_moved "PR_HEAD_SHA=$OTHER_SHA" SHA_NEWEST_RUN_ID=1
only "all-empty environment" SKIP:not_pull_request
only "event inputs ok, nothing gathered" SKIP:opus_job_missing \
  RUN_EVENT=pull_request RUN_CONCLUSION=failure RUN_ATTEMPT=1 RUN_ID=5 "RUN_HEAD_SHA=$SHA" RUN_PR_NUMBERS=7
only "everything gathered except the run listing" SKIP:newer_run "${BASE[@]}" SHA_NEWEST_RUN_ID= SHA_MAX_ATTEMPT=

echo "--- sourcing, and sync guards ---"
got=$(env -i PATH="$PATH" "${BASE[@]}" bash -c 'source "$1"; printf "[s]"; gate_infra_retry_decide' _ "$SCRIPT")
eq "sourcing prints nothing; the function decides" "$got" "[s]RETRY"
got=$(env -i PATH="$PATH" bash -c 'set -u; source "$1"; gate_infra_retry_decide' _ "$SCRIPT" 2>&1)
eq "unset variables under 'set -u' still decide (SKIP)" "$got" "SKIP:not_pull_request"
# The allowlist is frozen (widening it must be a deliberate edit of this test) and
# every token in it must be a real binding-verdict INFRA token.
got=$(env -i PATH="$PATH" bash -c 'source "$1"; source "$2"; printf "%s" "$RETRYABLE_INFRA_TOKENS"; for t in $RETRYABLE_INFRA_TOKENS; do [[ "$INFRA_TOKENS" == *" $t "* ]] || printf "!MISSING:%s" "$t"; done' _ "$SCRIPT" "$TEST_DIR/../gate_binding_verdict.sh")
eq "allowlist is exactly the three tokens, all in gate_binding_verdict.sh INFRA_TOKENS" "$got" " INSTALLATION_RATE_LIMIT_INFRA INSTALLATION_REST_THROTTLE_INFRA USAGE_CAP_INFRA "
# The description shape comes from the recorder; if it changes this must fire.
grep -qF 'DESC="opus-gate infra-neutral (${TOKEN})"' "$TEST_DIR/../post_opus_verdict_recorded.sh" && c=ok || c=drifted
eq "post_opus_verdict_recorded.sh still writes 'opus-gate infra-neutral (<TOKEN>)'" "$c" ok
got=$(env -i PATH="$PATH" bash -c 'source "$1"; printf "%s" "$INFRA_DESC_PREFIX"' _ "$SCRIPT")
eq "INFRA_DESC_PREFIX matches the recorder's prefix" "$got" "$P"

echo
if [ "$FAILS" -eq 0 ]; then echo "All gate_infra_retry_decide tests passed."; else echo "$FAILS gate_infra_retry_decide test(s) FAILED."; exit 1; fi

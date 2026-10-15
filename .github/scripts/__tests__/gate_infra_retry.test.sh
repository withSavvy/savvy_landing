#!/bin/bash
# Tests for gate_infra_retry.sh, the orchestrator that re-runs a Gate run's
# opus-gate job once on a self-clearing infra failure. [savvy-backend#1537, run
# 37237626545] A PATH-shim `gh` serves canned JSON per URL (through the real jq
# filters the script passes via --jq) and logs every call; `sleep` is shimmed too.
# Proven: exactly ONE write (POST actions/jobs/<id>/rerun) on an eligible failure;
# zero writes on every SKIP; the second gather is fresh (a PR that moves during the
# wait is not retried); a failed read means no retry; bad config fails before any
# API call.
# shellcheck disable=SC2016  # ck() takes its condition in single quotes and evals it after the fixtures exist
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../gate_infra_retry.sh"
FAILS=0
SHA="0123456789abcdef0123456789abcdef01234567"
OTHER_SHA="fedcba9876543210fedcba9876543210fedcba98"
REPO="withSavvy/savvy_landing"
RUN=37237626545
URL="https://github.com/${REPO}/actions/runs/${RUN}"
OPUS_JOB=222
GATE_P="opus-gate infra-neutral ("

[ -f "$SCRIPT" ] || { echo "Error: $SCRIPT not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required by this test's gh shim"; exit 1; }

# ck DESC CONDITION — eval the condition now.
ck() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1 [$2] out: $(tr '\n' '|' < "$SB/out" | cut -c1-300)"; FAILS=$((FAILS + 1)); fi; }

# --- fixtures: $SB/<route>.json is served always, $SB/<route>.<n>.json instead on the
# n-th request; $SB/fail_from.<route>=N fails every request from the N-th on;
# $SB/fail_first.<route>=K fails the first K with a rate-limit body (gh_retry retries).
# status_json STATE CREATOR URL DESC: the statuses list, newest first: an unrelated
# context, the status under test, then an OLDER success that must never be read.
status_json() {
  printf '[{"context":"scripts-tests","state":"success","creator":{"login":"github-actions[bot]"},"target_url":"x","description":"ok"},{"context":"opus-verdict-recorded","state":%s,"creator":{"login":%s},"target_url":%s,"description":%s},{"context":"opus-verdict-recorded","state":"success","creator":{"login":"github-actions[bot]"},"target_url":"%s","description":"opus-gate PASS"}]\n' \
    "$(jq -Rn --arg v "$1" '$v')" "$(jq -Rn --arg v "$2" '$v')" "$(jq -Rn --arg v "$3" '$v')" "$(jq -Rn --arg v "$4" '$v')" "$URL"
}
pr_json() { printf '{"state":"%s","head":{"sha":"%s"},"base":{"ref":"%s","repo":{"default_branch":"%s"}}}\n' "$1" "$2" "$3" "$4"; }
runs_json() { printf '{"workflow_runs":[{"id":%s,"event":"pull_request","run_attempt":%s},{"id":%s,"event":"pull_request","run_attempt":1},{"id":38000000000,"event":"push","run_attempt":3}]}\n' "$1" "$2" "$3"; }

setup() {
  SB="$(mktemp -d)"; mkdir -p "$SB/bin"; : > "$SB/calls"; : > "$SB/sleeps"; : > "$SB/out"; export SB
  echo "{\"jobs\":[{\"id\":111,\"name\":\"review\",\"conclusion\":\"success\"},{\"id\":${OPUS_JOB},\"name\":\"opus-gate\",\"conclusion\":\"failure\"},{\"id\":333,\"name\":\"record opus verdict\",\"conclusion\":\"success\"}]}" > "$SB/jobs.json"
  status_json failure "github-actions[bot]" "$URL" "${GATE_P}INSTALLATION_RATE_LIMIT_INFRA)" > "$SB/statuses.json"
  pr_json open "$SHA" main main > "$SB/pr.json"
  runs_json "$RUN" 1 37237000000 > "$SB/runs.json"
  cat > "$SB/bin/gh" <<'STUB'
#!/bin/bash
# fake gh: logs "<METHOD> <path>" per call, serves canned JSON through --jq.
if [ "${1:-}" != "api" ]; then echo "OTHER gh $*" >> "$SB/calls"; exit 99; fi
shift; method=GET; path=""; filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    --jq) filter="$2"; shift 2 ;;
    -*) echo "FLAG $1" >> "$SB/calls"; shift ;;
    *) path="$1"; shift ;;
  esac
done
echo "$method $path" >> "$SB/calls"
if [ "$method" != "GET" ]; then
  case "$path" in
    */actions/jobs/*/rerun)
      [ -f "$SB/post_fail" ] && { echo '{"message":"Resource not accessible by integration","status":"403"}' >&2; exit 1; }
      exit 0 ;;
  esac
  echo "unexpected write $method $path" >&2; exit 98
fi
case "$path" in
  */attempts/1/jobs\?*) route=jobs ;;
  */commits/*/statuses\?*) route=statuses ;;
  */actions/workflows/*/runs\?*) route=runs ;;
  */pulls/*) route=pr ;;
  *) echo "unexpected GET $path" >&2; exit 97 ;;
esac
n=$(( $(cat "$SB/count.$route" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SB/count.$route"
if [ -f "$SB/fail_first.$route" ] && [ "$n" -le "$(cat "$SB/fail_first.$route")" ]; then
  echo '{"message":"API rate limit exceeded for installation ID 1","status":"403"}' >&2; exit 1
fi
if [ -f "$SB/fail_from.$route" ] && [ "$n" -ge "$(cat "$SB/fail_from.$route")" ]; then
  echo '{"message":"Server Error","status":"500"}' >&2; exit 1
fi
file="$SB/$route.$n.json"; [ -f "$file" ] || file="$SB/$route.json"
jq -r "$filter" < "$file"
STUB
  printf '#!/bin/bash\necho "$*" >> "$SB/sleeps"\n' > "$SB/bin/sleep"
  chmod +x "$SB/bin/gh" "$SB/bin/sleep"
}
teardown() { rm -rf "$SB"; }

# run [VAR=VALUE ...] — the script with a full, eligible environment (later
# assignments win); prints the exit code; output lands in $SB/out.
run() {
  env -i PATH="$SB/bin:$PATH" HOME="$SB" SB="$SB" GH_TOKEN=dummy \
    GITHUB_REPOSITORY="$REPO" GITHUB_SERVER_URL=https://github.com \
    RUN_ID="$RUN" RUN_WORKFLOW_ID=555 RUN_EVENT=pull_request RUN_CONCLUSION=failure \
    RUN_ATTEMPT=1 "RUN_HEAD_SHA=$SHA" RUN_PR_NUMBERS=1537 RETRY_DELAY_SECONDS=0 \
    GATE_RETRY_SLEEP=0 GH_RETRY_RATE_LIMIT_MIN_SLEEP=0 GH_RETRY_RATE_LIMIT_JITTER_MAX=0 GH_RETRY_RATE_LIMIT_JITTER=0 GH_RETRY_RATE_LIMIT_SLEEP=0 GH_RETRY_RATELIMIT_WAIT=0 GH_RETRY_RATELIMIT_JITTER=0 \
    "$@" bash "$SCRIPT" > "$SB/out" 2>&1
  echo $?
}
n_posts()  { grep -c '^POST ' "$SB/calls" || true; }
n_writes() { grep -vc '^GET ' "$SB/calls" || true; }
n_gets()   { grep -c '^GET ' "$SB/calls" || true; }
n_calls()  { grep -c . "$SB/calls" || true; }
waited()   { grep -cx "$1" "$SB/sleeps" || true; }
# skip1 DESC CODE — the fixtures are already edited; the FIRST check must skip with
# CODE: no write, no wait, only the four first-gather reads.
skip1() {
  local rc; rc=$(run)
  ck "$1 -> $2, no write, no wait" "[ '$rc' = 0 ] && [ \"\$(n_writes)\" = 0 ] && [ \"\$(waited 600)\" = 0 ] && [ \"\$(n_gets)\" = 4 ] && grep -q 'first check: $2' '$SB/out'"
  teardown
}
# late DESC — the fixtures change on the SECOND read of one route: the re-check after the wait must skip.
late() {
  local rc; rc=$(run RETRY_DELAY_SECONDS=7)
  ck "$1 during the wait -> no POST" "[ '$rc' = 0 ] && [ \"\$(n_writes)\" = 0 ] && [ \"\$(waited 7)\" = 1 ] && [ \"\$(n_gets)\" = 8 ] && grep -q 're-check after wait: SKIP:' '$SB/out'"
  teardown
}

echo "--- (a) eligible failure: exactly one POST, nothing else is written ---"
setup; rc=$(run RETRY_DELAY_SECONDS=7)
ck "exit 0, one POST, and it is the only non-GET call (no flags, no other gh command)" "[ '$rc' = 0 ] && [ \"\$(n_posts)\" = 1 ] && [ \"\$(n_writes)\" = 1 ]"
ck "the POST targets actions/jobs/<opus-gate job id>/rerun, after both gathers" "[ \"\$(grep -n '^POST ' '$SB/calls')\" = '9:POST repos/${REPO}/actions/jobs/${OPUS_JOB}/rerun' ]"
ck "all four reads happen twice, and it waited RETRY_DELAY_SECONDS once" "[ \"\$(n_gets)\" = 8 ] && [ \"\$(cat '$SB/count.jobs')\$(cat '$SB/count.statuses')\$(cat '$SB/count.pr')\$(cat '$SB/count.runs')\" = 2222 ] && [ \"\$(waited 7)\" = 1 ]"
ck "the reads are the run's attempt-1 jobs, the SHA's statuses, the PR and the workflow's runs for the SHA" \
  "grep -qx 'GET repos/${REPO}/actions/runs/${RUN}/attempts/1/jobs?per_page=100' '$SB/calls' && grep -qx 'GET repos/${REPO}/commits/${SHA}/statuses?per_page=100' '$SB/calls' && grep -qx 'GET repos/${REPO}/pulls/1537' '$SB/calls' && grep -qx 'GET repos/${REPO}/actions/workflows/555/runs?head_sha=${SHA}&per_page=100' '$SB/calls'"
ck "it says what it re-ran" "grep -q 're-ran opus-gate job ${OPUS_JOB} of run ${RUN}' '$SB/out'"
teardown
for t in INSTALLATION_RATE_LIMIT_INFRA INSTALLATION_REST_THROTTLE_INFRA USAGE_CAP_INFRA; do
  setup; status_json failure "github-actions[bot]" "$URL" "${GATE_P}${t})" > "$SB/statuses.json"; rc=$(run)
  ck "token $t -> one POST" "[ '$rc' = 0 ] && [ \"\$(n_posts)\" = 1 ]"; teardown
done
setup; echo 1 > "$SB/fail_first.statuses"; echo 1 > "$SB/fail_first.pr"; rc=$(run)
ck "a transient rate limit on a read is retried by gh_retry, then one POST" "[ '$rc' = 0 ] && [ \"\$(n_posts)\" = 1 ]"; teardown

echo "--- (b) ineligible: zero writes, no wait ---"
for desc in "opus-gate floor block (needs human review)" "${GATE_P}AUTH_FAIL)" "${GATE_P}NO_EXEC_FILE_INFRA)" "${GATE_P}USAGE_CAP_INFRA) "; do
  setup; status_json failure "github-actions[bot]" "$URL" "$desc" > "$SB/statuses.json"; skip1 "description '$desc'" SKIP:token_not_retryable
done
setup; status_json success "github-actions[bot]" "$URL" "human-override by Sara3" > "$SB/statuses.json"; skip1 "human-override success" SKIP:status_not_failure
setup; status_json failure "Sara3" "$URL" "${GATE_P}USAGE_CAP_INFRA)" > "$SB/statuses.json"; skip1 "status not from github-actions[bot]" SKIP:status_not_from_actions
setup; status_json failure "github-actions[bot]" "${URL%?}6" "${GATE_P}USAGE_CAP_INFRA)" > "$SB/statuses.json"; skip1 "status of another run" SKIP:status_other_run
setup; echo '[{"context":"scripts-tests","state":"success","creator":{"login":"x"},"target_url":"x","description":"x"}]' > "$SB/statuses.json"; skip1 "no opus-verdict-recorded status yet" SKIP:status_missing
setup; status_json failure "github-actions[bot]" "$URL" "${GATE_P}USAGE_CAP_INFRA)
second line" > "$SB/statuses.json"; skip1 "description with a newline (control char)" SKIP:status_missing
setup; pr_json closed "$SHA" main main > "$SB/pr.json"; skip1 "PR closed" SKIP:pr_not_open
setup; pr_json open "$OTHER_SHA" main main > "$SB/pr.json"; skip1 "PR head already moved" SKIP:head_moved
setup; pr_json open "$SHA" release main > "$SB/pr.json"; skip1 "PR base is not the default branch" SKIP:base_not_default
setup; runs_json "$RUN" 2 37237000000 > "$SB/runs.json"; skip1 "the run is already at attempt 2" SKIP:already_retried
setup; runs_json "$RUN" 1 $((RUN + 5)) > "$SB/runs.json"; skip1 "a newer Gate run exists for the SHA" SKIP:newer_run
setup; echo '{"workflow_runs":[]}' > "$SB/runs.json"; skip1 "no pull_request run listed" SKIP:newer_run
setup; sed -i.bak 's/"conclusion":"failure"/"conclusion":"success"/' "$SB/jobs.json"; skip1 "opus-gate job did not fail" SKIP:opus_not_failed
setup; echo '{"jobs":[{"id":1,"name":"opus-gate","conclusion":"failure"},{"id":2,"name":"opus-gate","conclusion":"failure"}]}' > "$SB/jobs.json"; skip1 "two jobs named opus-gate" SKIP:opus_job_missing
for kv in RUN_EVENT=push RUN_CONCLUSION=success RUN_ATTEMPT=2; do
  setup; rc=$(run "$kv"); ck "$kv -> exit 0, no write" "[ '$rc' = 0 ] && [ \"\$(n_writes)\" = 0 ]"; teardown
done
for kv in RUN_PR_NUMBERS= "RUN_PR_NUMBERS=1537 1538" "RUN_PR_NUMBERS=1537/../../x"; do
  setup; rc=$(run "$kv"); ck "$kv -> exit 0, no write, no PR url built" "[ '$rc' = 0 ] && [ \"\$(n_writes)\" = 0 ] && ! grep -q '/pulls/' '$SB/calls'"; teardown
done

echo "--- (c) state changes during the wait: the fresh second gather catches it ---"
setup; pr_json open "$OTHER_SHA" main main > "$SB/pr.2.json"; late "head moved"
setup; pr_json closed "$SHA" main main > "$SB/pr.2.json"; late "PR closed"
setup; pr_json open "$SHA" release main > "$SB/pr.2.json"; late "PR retargeted"
setup; status_json success "github-actions[bot]" "$URL" "human-override by Sara3" > "$SB/statuses.2.json"; late "a human override landed"
setup; status_json failure "github-actions[bot]" "$URL" "${GATE_P}AUTH_FAIL)" > "$SB/statuses.2.json"; late "the status became a non-retryable token"
setup; runs_json "$RUN" 1 $((RUN + 9)) > "$SB/runs.2.json"; late "a newer Gate run appeared"
setup; runs_json "$RUN" 2 37237000000 > "$SB/runs.2.json"; late "someone else re-ran the run"

echo "--- (d) a read fails: zero POSTs, exit 0 ---"
for route in jobs statuses pr runs; do
  setup; echo 1 > "$SB/fail_from.$route"; rc=$(run)
  ck "first gather: '$route' fails -> no write, exit 0, no wait" "[ '$rc' = 0 ] && [ \"\$(n_writes)\" = 0 ] && [ \"\$(waited 600)\" = 0 ]"; teardown
  setup; echo 2 > "$SB/fail_from.$route"; rc=$(run RETRY_DELAY_SECONDS=7)
  ck "second gather: '$route' fails after the wait -> no write, exit 0" "[ '$rc' = 0 ] && [ \"\$(n_writes)\" = 0 ] && [ \"\$(waited 7)\" = 1 ]"; teardown
done
setup; echo 1 > "$SB/fail_from.statuses"; rc=$(run)
ck "a failed read is a ::warning:: plus a SKIP notice, not an error" "grep -q '::warning::gate-infra-retry: could not read the opus-verdict-recorded status' '$SB/out' && grep -q 'SKIP:status_missing' '$SB/out'"; teardown
setup; echo 2 > "$SB/fail_from.pr"; rc=$(run RETRY_DELAY_SECONDS=7)
ck "a failed second read does not reuse the first read's values" "[ '$rc' = 0 ] && [ \"\$(n_writes)\" = 0 ] && grep -q 're-check after wait: SKIP:pr_not_open' '$SB/out'"; teardown

echo "--- (e) RETRY_DELAY_SECONDS out of range or malformed: exit 1, no API call ---"
for bad in 5000 1201 -1 abc 1e3 "6 0" 123456; do
  setup; rc=$(run "RETRY_DELAY_SECONDS=$bad")
  ck "RETRY_DELAY_SECONDS='$bad' -> exit 1, no call, ::error::" "[ '$rc' = 1 ] && [ \"\$(n_calls)\" = 0 ] && grep -q '::error::gate-infra-retry: RETRY_DELAY_SECONDS' '$SB/out'"; teardown
done
setup; rc=$(run RETRY_DELAY_SECONDS=1200)
ck "1200 (the maximum) is accepted and waited once" "[ '$rc' = 0 ] && [ \"\$(waited 1200)\" = 1 ] && [ \"\$(n_posts)\" = 1 ]"; teardown
setup; rc=$(run RETRY_DELAY_SECONDS=)
ck "empty uses the 600s default" "[ '$rc' = 0 ] && [ \"\$(waited 600)\" = 1 ] && [ \"\$(n_posts)\" = 1 ]"; teardown

echo "--- (f) malformed ids or config: exit 1 before any URL is built ---"
for kv in RUN_ID=abc RUN_ID=123/../x RUN_ID= RUN_WORKFLOW_ID=abc RUN_WORKFLOW_ID=5/x RUN_WORKFLOW_ID= RUN_HEAD_SHA=0123456 \
          "RUN_HEAD_SHA=${SHA}/x" RUN_HEAD_SHA= GITHUB_REPOSITORY= GITHUB_REPOSITORY=a/b/c "GITHUB_REPOSITORY=a/b c" \
          GITHUB_SERVER_URL= GITHUB_SERVER_URL=http://github.com GH_TOKEN=; do
  setup; rc=$(run "$kv")
  ck "$kv -> exit 1, no API call" "[ '$rc' = 1 ] && [ \"\$(n_calls)\" = 0 ] && grep -q '::error::gate-infra-retry:' '$SB/out'"; teardown
done

echo "--- (g) the POST fails, and (h) log hygiene ---"
setup; touch "$SB/post_fail"; rc=$(run)
ck "POST rejected -> exit 1 with ::error::, attempted exactly once (not wrapped in gh_retry)" "[ '$rc' = 1 ] && [ \"\$(n_posts)\" = 1 ] && grep -q '::error::gate-infra-retry: re-run request for opus-gate job ${OPUS_JOB} failed' '$SB/out'"; teardown
setup; status_json failure "github-actions[bot]" "$URL" "::set-output name=x::y %0A bad" > "$SB/statuses.json"; rc=$(run)
ck "a hostile status description cannot inject a workflow command into the log" "[ '$rc' = 0 ] && ! grep -q '::set-output' '$SB/out' && grep -q 'SKIP:token_not_retryable' '$SB/out'"; teardown

echo
if [ "$FAILS" -eq 0 ]; then echo "All gate_infra_retry tests passed."; else echo "$FAILS gate_infra_retry test(s) FAILED."; exit 1; fi

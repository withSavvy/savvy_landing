#!/bin/bash
# Freezes the gate-infra-retry GUARANTEE for this repo: what the two behaviour suites
# (gate_infra_retry*.test.sh) cannot see. G5 (the only write is POST actions/jobs/<opus-gate
# job id>/rerun; no scope that can write a status), G6 (the recorder's own runner), the
# trigger and the untrusted-input surface. Static only. Ported from savvy-backend#1616's
# jest convention test, because this repo's CI runs bare-assert .github/scripts tests.
set -u # no pipefail: `printf ... | grep -q` would die of SIGPIPE on long inputs

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="$TEST_DIR/.."
WF="$GH/../workflows"
RETRY_RAW="$WF/gate-infra-retry.yml"
read -r RECORDER_RUNS_ON <<'EXPR_END'
${{ vars.CI_RUNNER || 'ubuntu-latest' }}
EXPR_END
RECORDER_JOB="record-opus-verdict"
RETRYABLE="INSTALLATION_RATE_LIMIT_INFRA INSTALLATION_REST_THROTTLE_INFRA USAGE_CAP_INFRA"
ALLOW_HOSTED="yes" # yes only where the recorder itself is hosted by design (public landing repo)
FAILS=0
ck() { if "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi; }
for f in "$RETRY_RAW" "$GH/gate_infra_retry.sh" "$GH/gate_infra_retry_decide.sh" "$GH/gate_binding_verdict.sh" "$GH/post_opus_verdict_recorded.sh" "$WF/gate.yml"; do
  [ -f "$f" ] || { echo "Error: $f not found"; exit 1; }
done
# whole-line comments removed (and, for YAML, trailing ` # ...`), as in the jest original
shcode() { grep -v '^[[:space:]]*#' "$1"; }
yamlcode() { shcode "$1" | sed 's/[[:space:]]#.*$//'; }
# jobkey FILE JOB KEY: the value of `    KEY:` inside one top-level job
jobkey() { awk -v job="  $2:" -v key="    $3:" '$0==job{f=1;next} f&&/^  [A-Za-z0-9_-]+:[ ]*$/{f=0} f&&index($0,key)==1{sub(/^ *[A-Za-z-]+: */,"");print;exit}' "$1"; }
CODE="$(yamlcode "$RETRY_RAW")"
JOB="$(printf '%s\n' "$CODE" | awk '/^  retry-opus-gate:[ ]*$/{f=1} f')"
ORCH="$(shcode "$GH/gate_infra_retry.sh")"
DECIDE="$(shcode "$GH/gate_infra_retry_decide.sh")"
GATE_YAML="$(yamlcode "$WF/gate.yml")"
has() { printf '%s\n' "$1" | grep -qxF -- "$2"; }
count() { printf '%s\n' "$1" | grep -cE -- "$2"; }

t_names() { has "$CODE" "name: Gate infra retry" && grep -qx "name: Gate" "$WF/gate.yml"; }
t_trigger() { [ "$(printf '%s\n' "$CODE" | awk '/^on:/{f=1} /^permissions:/{f=0} f')" = $'on:\n  workflow_run:\n    workflows: ["Gate"]\n    types: [completed]' ]; }
t_noperms() { [ "$(count "$CODE" '^permissions:')" = 1 ] && has "$CODE" "permissions: {}"; }
t_concurrency() { has "$CODE" '  group: gate-infra-retry-${{ github.event.workflow_run.head_sha }}' && has "$CODE" "  cancel-in-progress: false"; }
t_onejob() { [ "$(printf '%s\n' "$CODE" | awk '/^jobs:/{f=1;next} f&&/^  [A-Za-z0-9_-]+:[ ]*$/' | tr -d ' \n')" = "retry-opus-gate:" ] && [ "$(jobkey "$RETRY_RAW" retry-opus-gate timeout-minutes | sed 's/ *#.*//')" = 30 ]; }
t_if() { [ "$(jobkey "$RETRY_RAW" retry-opus-gate if)" = "\${{ github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion == 'failure' && github.event.workflow_run.run_attempt == 1 }}" ]; }
t_jobperms() { [ "$(printf '%s\n' "$JOB" | awk '/^    permissions:/{f=1;next} f&&/^      /{gsub(/^ +/,"");print;next} f{exit}' | sort | tr '\n' '|')" = "actions: write|contents: read|pull-requests: read|statuses: read|" ]; }
t_onewrite() { [ "$(count "$CODE" ':[ ]*write\b')" = 1 ] && ! grep -q "statuses: write" "$RETRY_RAW" && ! grep -qE '\bwrite-all\b|\b(checks|issues|pull-requests|contents|id-token|deployments):[ ]*write\b' "$RETRY_RAW"; }
t_secrets() { [ "$(printf '%s\n' "$CODE" | grep -oE 'secrets\.[A-Za-z0-9_]+' | sort -u | tr '\n' ' ')" = "secrets.GITHUB_TOKEN " ] && ! printf '%s\n' "$CODE" | grep -qiE 'app[-_]?token|create-github-app-token|CLAUDE_PAT'; }
t_runson() { [ "$(jobkey "$RETRY_RAW" retry-opus-gate runs-on)" = "$RECORDER_RUNS_ON" ] && [ "$(count "$CODE" 'runs-on:')" = 1 ]; }
t_recorder() { [ "$(jobkey "$WF/gate.yml" "$RECORDER_JOB" runs-on)" = "$RECORDER_RUNS_ON" ]; }
t_nohosted() { [ "$ALLOW_HOSTED" = yes ] || ! grep -qiE '\b(ubuntu|macos|windows)-' "$RETRY_RAW"; }
t_steps() {
  [ "$(count "$JOB" '^      - ')" = 2 ] && [ "$(count "$CODE" '^[[:space:]]*uses:')" = 1 ] &&
    printf '%s\n' "$JOB" | grep -q "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" &&
    ! printf '%s\n' "$CODE" | grep -qE '^[[:space:]]*ref:' &&
    has "$JOB" "          sparse-checkout: .github/scripts" && has "$JOB" "          persist-credentials: false" &&
    has "$JOB" "          bash .github/scripts/gate_infra_retry.sh"
}
t_env() {
  [ "$(printf '%s\n' "$JOB" | awk '/^        env:/{f=1;next} f&&/^          [A-Z_]+:/{sub(/^ +/,"");sub(/:.*/,"");printf "%s ",$0;next} f{exit}')" = "GH_TOKEN RUN_ID RUN_WORKFLOW_ID RUN_EVENT RUN_CONCLUSION RUN_ATTEMPT RUN_HEAD_SHA RUN_PR_NUMBERS RETRY_DELAY_SECONDS " ] &&
    has "$JOB" "          RETRY_DELAY_SECONDS: 600"
}
t_untrusted() {
  ! grep -qE 'head_branch|display_title|head_commit|head_repository' "$RETRY_RAW" &&
    ! grep -qE 'pull_requests(\[[^]]*\]|\.\*|\.[0-9]+)\.(head|base)|github\.head_ref|github\.event\.pull_request\.' "$RETRY_RAW"
}
t_exprs() {
  local allowed expr
  allowed="$(cat <<ALLOWED_END
github.event.workflow_run.head_sha
github.event.workflow_run.id
github.event.workflow_run.workflow_id
github.event.workflow_run.event
github.event.workflow_run.conclusion
github.event.workflow_run.run_attempt
join(github.event.workflow_run.pull_requests.*.number, ' ')
secrets.GITHUB_TOKEN
github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion == 'failure' && github.event.workflow_run.run_attempt == 1
${RECORDER_RUNS_ON#\$\{\{ }
ALLOWED_END
)"
  allowed="${allowed% \}\}}"
  while IFS= read -r expr; do
    [ -z "$expr" ] || printf '%s\n' "$allowed" | grep -qxF -- "$expr" || { echo "  unexpected expression: $expr"; return 1; }
  done < <(printf '%s\n' "$CODE" | grep -oE '\$\{\{[^}]*\}\}' | sed -E 's/^\$\{\{ *//; s/ *\}\}$//')
  ! printf '%s\n' "$JOB" | awk '/run: \|/{f=1} f' | grep -q '\${{'
}
POSTS="$(printf '%s\n' "$ORCH" | grep -- '-X POST')"
t_post() {
  [ "$(printf '%s\n' "$POSTS" | wc -l | tr -d ' ')" = 1 ] && printf '%s\n' "$POSTS" | grep -qF '"repos/${REPO}/actions/jobs/${OPUS_JOB_ID}/rerun"' &&
    ! printf '%s\n' "$POSTS" | grep -q gh_retry &&
    ! printf '%s\n' "$ORCH" | grep -qE -- '-X[[:space:]]+(GET|PUT|PATCH|DELETE)|--method|--input|--field|--raw-field|[[:space:]]-[fF][[:space:]]'
}
t_ghcalls() { [ "$(printf '%s\n' "$ORCH" | grep -oE '\bgh api\b' | wc -l | tr -d ' ')" = 2 ] && ! printf '%s\n' "$ORCH" | grep -qE '\bgh (pr|run|issue|label|workflow|repo|release|auth|secret|variable)\b'; }
t_nowrites() { ! printf '%s\n' "$ORCH" | grep -qE 'statuses/|\bstate=|-f[[:space:]]*context|--add-label|--remove-label|/labels\b|/comments\b|issues/|/check-runs|/check-suites|rerun-failed-jobs|gh run rerun|actions/runs/\$\{RUN_ID\}/rerun|/cancel\b|force-cancel|dispatches'; }
at() { printf '%s\n' "$ORCH" | grep -nF -- "$1" | head -1 | cut -d: -f1; }
t_order() {
  local first wait recheck post
  first="$(at 'check "first check"')"; wait="$(at 'sleep "$DELAY"')"; recheck="$(at 'check "re-check after wait"')"; post="$(at '-X POST')"
  [ -n "$first" ] && [ "$wait" -gt "$first" ] && [ "$recheck" -gt "$wait" ] && [ "$post" -gt "$recheck" ] &&
    printf '%s\n' "$ORCH" | grep -qF 'MAX_DELAY_SECONDS=1200' && [ "$(at 'RUN_ID is not numeric')" -lt "$(at 'fetch_fields 2')" ]
}
t_pure() { ! printf '%s\n' "$DECIDE" | grep -qwE 'gh|curl|wget|sleep|date|nc' && ! printf '%s\n' "$DECIDE" | grep -qE '>>?[[:space:]]*[^ &]'; }
t_allowlist() { [ "$(env -i PATH="$PATH" bash -c 'source "$1"; printf %s "$RETRYABLE_INFRA_TOKENS"' _ "$GH/gate_infra_retry_decide.sh")" = " $RETRYABLE " ]; }
t_realtokens() { env -i PATH="$PATH" bash -c 'source "$1"; source "$2"; for t in $RETRYABLE_INFRA_TOKENS; do [[ "$INFRA_TOKENS" == *" $t "* ]] || exit 1; done' _ "$GH/gate_infra_retry_decide.sh" "$GH/gate_binding_verdict.sh"; }
t_recorder_sync() {
  grep -qF 'DESC="opus-gate infra-neutral (${TOKEN})"' "$GH/post_opus_verdict_recorded.sh" &&
    grep -qF 'target_url=${RUN_URL}' "$GH/post_opus_verdict_recorded.sh" &&
    printf '%s\n' "$DECIDE" | grep -qF 'INFRA_DESC_PREFIX="opus-gate infra-neutral ("' &&
    printf '%s\n' "$ORCH" | grep -qF 'JOB_NAME="opus-gate"' && printf '%s\n' "$ORCH" | grep -qF 'STATUS_CONTEXT="opus-verdict-recorded"'
}
t_gatejob() { has "$GATE_YAML" "    name: opus-gate"; }

echo "--- the workflow (trigger, concurrency, job filter) ---"
ck "named 'Gate infra retry'; gate.yml's top-level name is 'Gate'" t_names
ck 'the ONLY trigger is workflow_run of ["Gate"] types [completed]' t_trigger
ck "workflow permissions are {} (the only top-level permissions key)" t_noperms
ck "concurrency is per head SHA and never cancels a waiting retry" t_concurrency
ck "exactly one job (retry-opus-gate), 30 minute timeout" t_onejob
ck "job-level if keeps successful, cancelled, non-PR and attempt-2+ runs off the runner" t_if
echo "--- G5: the token can re-run a job and write nothing else ---"
ck "job permissions are EXACTLY actions: write, contents: read, pull-requests: read, statuses: read" t_jobperms
ck "actions: write is the only write scope; statuses: write appears nowhere (comments included)" t_onewrite
ck "GITHUB_TOKEN is the only secret: no PAT, no app token" t_secrets
echo "--- G6: the recorder's own runner ---"
ck "runs-on is exactly the recorder expression and the only runs-on" t_runson
ck "gate.yml's recorder job ($RECORDER_JOB) still uses that expression" t_recorder
ck "no hosted runner label (unless the recorder is hosted by design: public landing repo)" t_nohosted
echo "--- trusted default-branch code, minimal untrusted-input surface ---"
ck "two steps: a pinned, ref-less, credential-less sparse checkout of .github/scripts, then the orchestrator" t_steps
ck "the orchestrator env is exactly the event ids, the token and the delay (600)" t_env
ck "no attacker-influenced payload field appears anywhere, comments included" t_untrusted
ck 'every ${{ }} expression is on a fixed allowlist, and none is inside run:' t_exprs
echo "--- G5: the orchestrator's only write is POST actions/jobs/<opus-gate job id>/rerun ---"
ck "exactly one -X POST, to actions/jobs/\${OPUS_JOB_ID}/rerun, single-shot (not via gh_retry), no body" t_post
ck "exactly two gh api calls (the gh_retry read helper and that POST) and no other gh command" t_ghcalls
ck "never touches statuses, labels, comments, issues, checks, or any other re-run/cancel/dispatch endpoint" t_nowrites
ck "order: first check, the wait, a fresh re-check, then the POST; delay capped before any API call" t_order
echo "--- G1/G3: the decision is pure and the retryable allowlist is frozen ---"
ck "the decision script does no I/O: no gh, curl, wget, sleep, date or file writes" t_pure
ck "RETRYABLE_INFRA_TOKENS is exactly: $RETRYABLE" t_allowlist
ck "every retryable token is a real binding-verdict INFRA token" t_realtokens
ck "recorder still writes 'opus-gate infra-neutral (<TOKEN>)' + run-url target_url; decide/orchestrator still match" t_recorder_sync
ck "gate.yml still has a job named opus-gate" t_gatejob

if [ "$FAILS" -eq 0 ]; then echo "All gate_infra_retry_guarantee tests passed."; else echo "$FAILS gate_infra_retry_guarantee test(s) FAILED."; exit 1; fi

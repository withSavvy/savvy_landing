#!/bin/bash
# Tests for post_opus_verdict_recorded.sh — the `opus-verdict-recorded` status
# poster. [savvy-backend#1595 / tracking #1239] Success ONLY for the explicit
# allowlist; a crash/infra/anything-else is failure; a human override on the
# same SHA is never clobbered; a POST failure exits 1.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../post_opus_verdict_recorded.sh"
FAILS=0
SHA="0123456789abcdef0123456789abcdef01234567"

[ -f "$SCRIPT" ] || { echo "Error: $SCRIPT not found"; exit 1; }

assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILS=$((FAILS + 1)); fi
}

# setup: a fake gh. GET .../statuses returns $SB/existing (the pre-rendered
# "state|creator|description" line, empty = no prior status); POST
# .../statuses/<sha> is recorded to $SB/posts and fails when $SB/post_fail exists.
setup() {
  SB="$(mktemp -d)"; mkdir -p "$SB/bin"; : > "$SB/posts"; : > "$SB/calls"; : > "$SB/existing"
  printf 'package.json\n' > "$SB/files"
  cat > "$SB/bin/gh" <<STUB
#!/bin/bash
echo "\$*" >> "$SB/calls"
if [ "\$1" = "api" ] && [ "\$2" = "-X" ] && [ "\$3" = "POST" ]; then
  [ -f "$SB/post_fail" ] && { echo '{"message":"Server Error","status":"500"}' >&2; exit 1; }
  echo "\$*" >> "$SB/posts"; exit 0
fi
if [ "\$1" = "api" ] && [[ "\$*" == *"/pulls/"*"/files"* ]]; then
  [ -f "$SB/files_fail" ] && { echo '{"message":"boom","status":"502"}' >&2; exit 1; }
  cat "$SB/files"; exit 0
fi
if [ "\$1" = "api" ] && [[ "\$*" == *"/statuses?per_page"* ]]; then
  [ -f "$SB/read_fail" ] && { echo '{"message":"boom","status":"500"}' >&2; exit 1; }
  cat "$SB/existing"; exit 0
fi
exit 0
STUB
  chmod +x "$SB/bin/gh"
}
teardown() { rm -rf "$SB"; }

# run RESULT VERDICT ACTOR [SHA] — prints exit code; posts land in $SB/posts
run() {
  PATH="$SB/bin:$PATH" GITHUB_REPOSITORY="withSavvy/savvy_landing" GATE_RETRY_SLEEP=0 PR_NUMBER="${T_PR-7}" \
    bash "$SCRIPT" "$1" "$2" "$3" "${4:-$SHA}" "https://github.com/withSavvy/savvy_landing/actions/runs/1" > "$SB/out" 2>&1
  echo $?
}
state_of()  { sed -n 's/.*-f state=\([a-z]*\).*/\1/p' "$SB/posts" | tail -1; }
desc_of()   { sed -n 's/.*-f description=\(.*\) -f target_url=.*/\1/p' "$SB/posts" | tail -1; }

# expect DESC WANT_STATE RESULT VERDICT ACTOR
expect() {
  local desc="$1" want="$2" rc got; shift 2
  setup; rc=$(run "$@"); got="$(state_of)"
  if [ "$rc" = "0" ] && [ "$got" = "$want" ]; then assert "$desc" 0; else assert "$desc (rc=$rc state='$got' want '$want')" 1; fi
  teardown
}

echo "--- success allowlist ---"
expect "success + PASS -> success" success success PASS Sara3
expect "success + NOT_REQUIRED:trivial -> success" success success "NOT_REQUIRED:trivial" Sara3
expect "skipped + dependabot[bot] -> success (opus-gate skips dependabot by design)" success skipped "" "dependabot[bot]"

echo "--- dependabot + CI-surface (this repo's dependabot only bumps github-actions) ---"
dep() { # dep DESC WANT_STATE FILES... ; FILES empty-string "FAIL" = file list unreadable
  local desc="$1" want="$2" files="$3" rc got
  setup
  if [ "$files" = "FAIL" ]; then touch "$SB/files_fail"; else printf '%s\n' "$files" > "$SB/files"; fi
  rc=$(run skipped "" "dependabot[bot]"); got="$(state_of)"
  if [ "$rc" = "0" ] && [ "$got" = "$want" ]; then assert "$desc" 0; else assert "$desc (rc=$rc state='$got' want '$want')" 1; fi
  LAST_DESC="$(desc_of)"; teardown
}
dep "dependabot + a workflow file -> failure (CI-surface gets no free pass)" failure ".github/workflows/ci.yml"
[ "$LAST_DESC" = "opus-gate floor block (dependabot CI-surface)" ] && c=0 || c=1
assert "dependabot CI-surface description (got '$LAST_DESC')" "$c"
dep "dependabot + a .github/scripts file -> failure" failure "$(printf 'README.md\n.github/scripts/x.sh')"
dep "dependabot + .github/dependabot.yml -> failure" failure ".github/dependabot.yml"
dep "dependabot + .github/CODEOWNERS -> failure" failure ".github/CODEOWNERS"
dep "dependabot + .claude/scripts/ file -> failure" failure ".claude/scripts/x.js"
dep "dependabot + only non-CI-surface files -> success" success "$(printf 'package.json\npackage-lock.json')"
dep "dependabot + unreadable PR file list -> failure (fail-closed)" failure "FAIL"
setup; rc=$(T_PR="" run skipped "" "dependabot[bot]"); got="$(state_of)"
{ [ "$rc" = "0" ] && [ "$got" = "failure" ]; } && c=0 || c=1
assert "dependabot + no PR number -> failure (fail-closed)" "$c"
teardown
setup; rc=$(run skipped "" Sara3); got="$(state_of)"
{ [ "$rc" = "0" ] && [ "$got" = "failure" ] && ! grep -q '/pulls/' "$SB/calls"; } && c=0 || c=1
assert "a non-dependabot skip never even reads the file list and stays failure" "$c"
teardown

echo "--- everything else -> failure ---"
expect "skipped + human actor -> failure" failure skipped "" Sara3
expect "skipped + dependabot lookalike -> failure" failure skipped "" "dependabot-fake[bot]"
expect "success + dependabot but a verdict-less success? (non-skipped) -> failure" failure success "" "dependabot[bot]"
expect "failure + PASS (inconsistent) -> failure" failure failure PASS Sara3
expect "cancelled + empty verdict -> failure" failure cancelled "" Sara3
expect "empty result + empty verdict -> failure" failure "" "" Sara3
expect "success + empty verdict (output missing) -> failure" failure success "" Sara3
expect "success + unknown verdict -> failure" failure success "SOMETHING_NEW" Sara3
expect "success + lean/sonnet-clean style NOT_REQUIRED:lean-spend-mode -> failure (not an allowlisted class)" failure success "NOT_REQUIRED:lean-spend-mode" Sara3
expect "success + NOT_REQUIRED:docs-only -> failure" failure success "NOT_REQUIRED:docs-only" Sara3
expect "success + FAIL -> failure" failure success FAIL Sara3
expect "failure + FLOOR -> failure" failure failure FLOOR Sara3
expect "failure + ROUTE_HUMAN -> failure" failure failure ROUTE_HUMAN Sara3
expect "success-looking job but INFRA verdict -> failure (never success)" failure success "INFRA:NO_EXEC_FILE_INFRA" Sara3
expect "failure + INFRA verdict -> failure" failure failure "INFRA:NO_EXEC_FILE_INFRA" Sara3

echo "--- descriptions ---"
setup; run failure "INFRA:NO_EXEC_FILE_INFRA" Sara3 >/dev/null
[ "$(desc_of)" = "opus-gate infra-neutral (NO_EXEC_FILE_INFRA)" ] && c=0 || c=1
assert "INFRA description has the 'opus-gate infra-neutral (<TOKEN>)' shape (got '$(desc_of)')" "$c"
teardown
setup; run failure "INFRA:RUNNER_SANDBOX_MISSING_INFRA" Sara3 >/dev/null
L=$(desc_of); [ "${#L}" -le 140 ] && c=0 || c=1
assert "every description is at most 140 chars" "$c"
teardown
setup; run failure 'INFRA:x" -f state=success' Sara3 >/dev/null
grep -q 'unrecognised token' "$SB/posts" && ! grep -q 'state=success' "$SB/posts" && c=0 || c=1
assert "a malformed INFRA token is never echoed into the description" "$c"
teardown

echo "--- human override is never overwritten ---"
setup; echo "success|github-actions[bot]|human-override by Sara3 for 0123456" > "$SB/existing"
rc=$(run failure "INFRA:NO_EXEC_FILE_INFRA" Sara3)
{ [ "$rc" = "0" ] && [ ! -s "$SB/posts" ]; } && c=0 || c=1
assert "same-SHA human-override + a failing verdict -> NO post, exit 0" "$c"
teardown
setup; echo "success|github-actions[bot]|human-override by Sara3 for 0123456" > "$SB/existing"
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ ! -s "$SB/posts" ]; } && c=0 || c=1
assert "same-SHA human-override + a PASS verdict -> no post either (override stays authoritative)" "$c"
teardown
setup; echo "failure|github-actions[bot]|opus-gate infra-neutral (NO_EXEC_FILE_INFRA)" > "$SB/existing"
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ "$(state_of)" = "success" ]; } && c=0 || c=1
assert "prior failure on the SHA is overwritten by a later PASS (re-run heals)" "$c"
teardown
setup; echo "success|github-actions[bot]|opus-gate PASS" > "$SB/existing"
rc=$(run failure "INFRA:NO_EXEC_FILE_INFRA" Sara3)
{ [ "$rc" = "0" ] && [ "$(state_of)" = "failure" ]; } && c=0 || c=1
assert "prior ordinary success is overwritten by a later crash (re-run on same SHA can only go down)" "$c"
teardown
setup; echo "success|Sara3|human-override by fake" > "$SB/existing"
rc=$(run failure FAIL Sara3)
{ [ "$rc" = "0" ] && [ "$(state_of)" = "failure" ]; } && c=0 || c=1
assert "a 'human-override' description from a non-github-actions creator is NOT honoured" "$c"
teardown
setup; echo "failure|github-actions[bot]|human-override by Sara3 for 0123456" > "$SB/existing"
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ "$(state_of)" = "success" ]; } && c=0 || c=1
assert "a failure-state status is not an override even if its text says human-override" "$c"
teardown

echo "--- failures ---"
setup; touch "$SB/post_fail"
rc=$(run success PASS Sara3)
[ "$rc" = "1" ] && c=0 || c=1
assert "POST fails after retries -> exit 1 (job fails loud; context stays missing)" "$c"
teardown
setup; touch "$SB/read_fail"
rc=$(run failure FAIL Sara3)
{ [ "$rc" = "0" ] && [ "$(state_of)" = "failure" ]; } && c=0 || c=1
assert "override-check read fails -> still posts (fail-closed bias), exit 0" "$c"
teardown
setup
rc=$(run success PASS Sara3 "notasha")
[ "$rc" = "1" ] && [ ! -s "$SB/posts" ] && c=0 || c=1
assert "malformed head sha -> exit 1, no post" "$c"
teardown
setup
rc=$(PATH="$SB/bin:$PATH" GATE_RETRY_SLEEP=0 env -u GITHUB_REPOSITORY bash "$SCRIPT" success PASS Sara3 "$SHA" >/dev/null 2>&1; echo $?)
[ "$rc" = "1" ] && c=0 || c=1
assert "GITHUB_REPOSITORY unset -> exit 1" "$c"
teardown

echo "--- post shape ---"
setup; run success PASS Sara3 >/dev/null
grep -q "api -X POST repos/withSavvy/savvy_landing/statuses/${SHA}" "$SB/posts" \
  && grep -q -- "-f context=opus-verdict-recorded" "$SB/posts" \
  && grep -q -- "-f target_url=https://github.com/withSavvy/savvy_landing/actions/runs/1" "$SB/posts" && c=0 || c=1
assert "POSTs context=opus-verdict-recorded to the PR head SHA with the run url" "$c"
teardown

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

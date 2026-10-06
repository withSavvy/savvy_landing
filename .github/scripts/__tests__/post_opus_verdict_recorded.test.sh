#!/bin/bash
# Tests for post_opus_verdict_recorded.sh — the `opus-verdict-recorded` status
# poster. [savvy-backend#1595 / tracking #1239] Success ONLY for the explicit
# allowlist; a crash/infra/anything-else is failure; a human override on the
# same SHA is never clobbered; a POST failure exits 1.
# [2026-10-02] The recorder RE-DERIVES the CI-surface floor from the API (a PR
# touching only .github/scripts/ is a failure), mints a status only for a PR
# whose LIVE base is the default branch, and refuses a by-design (no-Opus) pass
# for a PR with more than 100 changed files.
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

# set_files LINES — the PR's file list the fake API returns, one per line:
# `name` or `new>old` (a rename; previous_filename=old). The stub applies the
# caller's own --jq expression to this JSON, so the recorder's jq is exercised.
# changed_files in the fake PR defaults to the number of listed files.
set_files() {
  printf '%s\n' "$1" | jq -R -s 'split("\n") | map(select(length>0)) | map(if contains(">") then {filename: (split(">")[0]), previous_filename: (split(">")[1]), status:"renamed"} else {filename: ., status:"modified"} end)' > "$SB/files.json"
  set_pr "${2-main}" "$(jq length "$SB/files.json")"
}
# set_pr BASE_REF CHANGED_FILES — the live PR the fake API returns.
# 3rd arg = live head sha (defaults to the event head $SHA).
set_pr() { echo "{\"base\":{\"ref\":\"$1\"},\"changed_files\":$2,\"head\":{\"sha\":\"${3:-$SHA}\"}}" > "$SB/pull.json"; }

# setup: a fake gh. GET .../statuses returns $SB/existing (the pre-rendered
# "state|creator|description" line, empty = no prior status); POST
# .../statuses/<sha> is recorded to $SB/posts and fails when $SB/post_fail exists.
# The PR, repo and files reads apply the caller's --jq to canned JSON.
setup() {
  SB="$(mktemp -d)"; mkdir -p "$SB/bin"; : > "$SB/posts"; : > "$SB/calls"; : > "$SB/existing"
  set_files 'package.json'
  echo '{"default_branch":"main"}' > "$SB/repo.json"
  cat > "$SB/bin/gh" <<STUB
#!/bin/bash
echo "\$*" >> "$SB/calls"
jqrun() { local expr="" prev=""; for a in "\$@"; do [ "\$prev" = "--jq" ] && expr="\$a"; prev="\$a"; done; jq -r "\$expr" "\$SB_FILE"; }
if [ "\$1" = "api" ] && [ "\$2" = "-X" ] && [ "\$3" = "POST" ]; then
  [ -f "$SB/post_fail" ] && { echo '{"message":"Server Error","status":"500"}' >&2; exit 1; }
  echo "\$*" >> "$SB/posts"; exit 0
fi
if [ "\$1" = "api" ] && [[ "\$*" == *"/pulls/"*"/files"* ]]; then
  [ -f "$SB/files_fail" ] && { echo '{"message":"boom","status":"502"}' >&2; exit 1; }
  : > "$SB/files_read"; SB_FILE="$SB/files.json" jqrun "\$@"; exit 0
fi
if [ "\$1" = "api" ] && [[ "\$2" == repos/*/pulls/[0-9]* ]]; then
  [ -f "$SB/pull_fail" ] && { echo '{"message":"boom","status":"502"}' >&2; exit 1; }
  PF="$SB/pull.json"; [ -f "$SB/files_read" ] && [ -f "$SB/pull_after.json" ] && PF="$SB/pull_after.json"
  SB_FILE="\$PF" jqrun "\$@"; exit 0
fi
if [ "\$1" = "api" ] && [[ "\$2" =~ ^repos/[^/]+/[^/]+$ ]]; then
  [ -f "$SB/repo_fail" ] && { echo '{"message":"boom","status":"502"}' >&2; exit 1; }
  SB_FILE="$SB/repo.json" jqrun "\$@"; exit 0
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
  if [ "$files" = "FAIL" ]; then touch "$SB/files_fail"; else set_files "$files"; fi
  rc=$(run skipped "" "dependabot[bot]"); got="$(state_of)"
  if [ "$rc" = "0" ] && [ "$got" = "$want" ]; then assert "$desc" 0; else assert "$desc (rc=$rc state='$got' want '$want')" 1; fi
  LAST_DESC="$(desc_of)"; teardown
}
dep "dependabot + a workflow file -> failure (CI-surface gets no free pass)" failure ".github/workflows/ci.yml"
[ "$LAST_DESC" = "FLOOR: CI-surface change — human release required" ] && c=0 || c=1
assert "dependabot CI-surface description is the FLOOR text (got '$LAST_DESC')" "$c"
dep "dependabot + a .github/scripts file -> failure" failure "$(printf 'README.md\n.github/scripts/x.sh')"
dep "dependabot + .github/dependabot.yml -> failure" failure ".github/dependabot.yml"
dep "dependabot + .github/CODEOWNERS -> failure" failure ".github/CODEOWNERS"
dep "dependabot + .claude/scripts/ file -> failure" failure ".claude/scripts/x.js"
dep "dependabot + only non-CI-surface files -> success" success "$(printf 'package.json\npackage-lock.json')"
dep "dependabot + unreadable PR file list -> failure (fail-closed)" failure "FAIL"
setup; rc=$(run skipped "" Sara3); got="$(state_of)"
{ [ "$rc" = "0" ] && [ "$got" = "failure" ]; } && c=0 || c=1
assert "a non-dependabot skip stays failure" "$c"
teardown


echo "--- CI-surface FLOOR: the recorder re-derives the file list itself ---"
FLOOR_WANT="FLOOR: CI-surface change — human release required"
floor() { # floor DESC WANT_STATE FILES RESULT VERDICT ACTOR ; FILES "FAIL" = API error, "EMPTY" = empty list
  local desc="$1" want="$2" files="$3" rc got; shift 3
  setup
  if [ "$files" = "FAIL" ]; then touch "$SB/files_fail"
  elif [ "$files" = "EMPTY" ]; then echo '[]' > "$SB/files.json"; set_pr main 0
  else set_files "$files"; fi
  rc=$(run "$@"); got="$(state_of)"
  if [ "$rc" = "0" ] && [ "$got" = "$want" ]; then assert "$desc" 0; else assert "$desc (rc=$rc state='$got' want '$want')" 1; fi
  LAST_DESC="$(desc_of)"; teardown
}
floor "PASS + only .github/scripts/gh_retry.sh -> failure (a script-only PR needs a human)" failure ".github/scripts/gh_retry.sh" success PASS Sara3
[ "$LAST_DESC" = "$FLOOR_WANT" ] && c=0 || c=1
assert "script-only FLOOR description (got '$LAST_DESC')" "$c"
floor "PASS + a workflow file -> failure (an Opus PASS never greens a CI-surface PR)" failure ".github/workflows/ci.yml" success PASS Sara3
floor "NOT_REQUIRED:trivial + a workflow file -> failure" failure ".github/workflows/gate.yml" success "NOT_REQUIRED:trivial" Sara3
floor "PASS + .claude/scripts file among others -> failure" failure "$(printf 'README.md\n.claude/scripts/x.js')" success PASS Sara3
floor "PASS + .github/CODEOWNERS -> failure" failure ".github/CODEOWNERS" success PASS Sara3
floor "PASS + file RENAMED OUT of .github/scripts (previous_filename) -> failure" failure "scripts/moved.sh>.github/scripts/gate.sh" success PASS Sara3
floor "PASS + file renamed INTO .github/workflows -> failure" failure ".github/workflows/new.yml>docs/new.yml" success PASS Sara3
floor "PASS + only non-CI-surface files -> success" success "$(printf 'index.html\nAssets/a.png\n.github/ISSUE_TEMPLATE/x.md')" success PASS Sara3
floor "PASS + look-alike paths (not under .github/scripts/) -> success" success "$(printf 'docs/.github/scripts/x.md\n.githubx/workflows/a.yml')" success PASS Sara3
floor "PASS + unreadable PR file list -> failure (fail-closed)" failure "FAIL" success PASS Sara3
[ "$LAST_DESC" = "FLOOR: could not read PR files — human release required" ] && c=0 || c=1
assert "unreadable-list description (got '$LAST_DESC')" "$c"
floor "PASS + EMPTY PR file list -> failure (fail-closed)" failure "EMPTY" success PASS Sara3
floor "INFRA verdict + CI-surface -> FLOOR failure description wins" failure ".github/workflows/ci.yml" failure "INFRA:NO_EXEC_FILE_INFRA" Sara3
[ "$LAST_DESC" = "$FLOOR_WANT" ] && c=0 || c=1
assert "floor wins over an upstream INFRA verdict in the description" "$c"
setup; set_files "index.html"; set_pr main 5   # the API listed 1 of 5 files: truncated
rc=$(run success PASS Sara3); got="$(state_of)"
{ [ "$rc" = "0" ] && [ "$got" = "failure" ] && [ "$(desc_of)" = "FLOOR: PR file list truncated by the API — human release required" ]; } && c=0 || c=1
assert "a file list shorter than changed_files (API cap) -> failure (could hide a CI-surface path)" "$c"
teardown
setup; rc=$(T_PR="" run success PASS Sara3)
{ [ "$rc" = "1" ] && [ ! -s "$SB/posts" ] && ! grep -q '/pulls/' "$SB/calls"; } && c=0 || c=1
assert "no PR number -> exit 1, nothing posted, no API call (fail-closed)" "$c"
teardown
setup; rc=$(T_PR="7; rm -rf /" run success PASS Sara3)
{ [ "$rc" = "1" ] && [ ! -s "$SB/posts" ] && ! grep -q '/pulls/' "$SB/calls"; } && c=0 || c=1
assert "non-numeric PR number is never interpolated into an API path" "$c"
teardown

echo "--- default-branch base guard (live API) ---"
setup; set_pr release/1 1
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ ! -s "$SB/posts" ] && ! grep -q '/files' "$SB/calls"; } && c=0 || c=1
assert "live PR base != default branch -> NO post, exit 0, files never read" "$c"
teardown
setup; set_pr Main 1
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ ! -s "$SB/posts" ]; } && c=0 || c=1
assert "branch compare is exact (Main != main) -> no post" "$c"
teardown
setup; echo '{"default_branch":"trunk"}' > "$SB/repo.json"; set_pr trunk 1
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ "$(state_of)" = "success" ]; } && c=0 || c=1
assert "the default branch comes from the repo API, not a hard-coded 'main'" "$c"
teardown
setup; touch "$SB/pull_fail"
rc=$(run success PASS Sara3)
{ [ "$rc" = "1" ] && [ ! -s "$SB/posts" ]; } && c=0 || c=1
assert "live PR read fails -> exit 1, nothing posted (fail-closed)" "$c"
teardown
setup; touch "$SB/repo_fail"
rc=$(run success PASS Sara3)
{ [ "$rc" = "1" ] && [ ! -s "$SB/posts" ]; } && c=0 || c=1
assert "repo (default branch) read fails -> exit 1, nothing posted (fail-closed)" "$c"
teardown
setup; echo '{"base":{"ref":"main"},"head":{"sha":"'"$SHA"'"}}' > "$SB/pull.json"
rc=$(run success PASS Sara3)
{ [ "$rc" = "1" ] && [ ! -s "$SB/posts" ]; } && c=0 || c=1
assert "changed_files missing from the live PR -> exit 1, nothing posted" "$c"
teardown

echo "--- stale-run guard: live head must equal the event head ---"
OTHER="fedcba9876543210fedcba9876543210fedcba98"
setup; set_pr main 1 "$OTHER"   # clean files, but the PR head has moved on
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ ! -s "$SB/posts" ] && ! grep -q '/files' "$SB/calls" && grep -q 'stale run' "$SB/out"; } && c=0 || c=1
assert "re-run case: live head != event head, clean stubbed files -> NO post, exit 0" "$c"
teardown
setup; set_files ".github/scripts/gh_retry.sh"; set_pr main 1 "$OTHER"
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ ! -s "$SB/posts" ]; } && c=0 || c=1
assert "live head != event head -> no post (neither success nor failure on the stale SHA)" "$c"
teardown
setup; set_pr main 1; set_pr main 1 "$OTHER"; cp "$SB/pull.json" "$SB/pull_after.json"; set_pr main 1
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ ! -s "$SB/posts" ]; } && c=0 || c=1
assert "head moves DURING the files fetch (push race) -> NO post" "$c"
teardown
setup; set_pr main 1; cp "$SB/pull.json" "$SB/pull_after.json"
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ "$(state_of)" = "success" ]; } && c=0 || c=1
assert "head stable across both reads -> success still posts" "$c"
teardown
setup; echo '{"base":{"ref":"main"},"changed_files":1}' > "$SB/pull.json"
rc=$(run success PASS Sara3)
{ [ "$rc" = "0" ] && [ ! -s "$SB/posts" ]; } && c=0 || c=1
assert "live head.sha missing -> treated as stale, nothing posted" "$c"
teardown

echo "--- trivial cap: > 100 changed files is never trivial ---"
big() { # big DESC WANT RESULT VERDICT ACTOR N
  local desc="$1" want="$2" n="$6" rc got; shift 2
  setup; set_files "$(seq 1 "$n" | sed 's#^#f/#')"
  rc=$(run "$1" "$2" "$3"); got="$(state_of)"
  if [ "$rc" = "0" ] && [ "$got" = "$want" ]; then assert "$desc" 0; else assert "$desc (rc=$rc state='$got' want '$want')" 1; fi
  teardown
}
big "NOT_REQUIRED:trivial with 101 files -> failure (Opus must run)" failure success "NOT_REQUIRED:trivial" Sara3 101
big "NOT_REQUIRED:trivial with exactly 100 files -> success" success success "NOT_REQUIRED:trivial" Sara3 100
big "dependabot skip with 101 files -> failure" failure skipped "" "dependabot[bot]" 101
big "dependabot skip with 100 files -> success" success skipped "" "dependabot[bot]" 100
big "a real Opus PASS with 101 files -> success (Opus did review it)" success success PASS Sara3 101

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

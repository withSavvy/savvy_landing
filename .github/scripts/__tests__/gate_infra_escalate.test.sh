#!/bin/bash
# Fixture tests for gate_infra_escalate.sh — the shared Type-C ("couldn't
# run") escalation used by every gate check's crash paths.
# [savvy-backend#1595 / tracking #1239, ported to savvy_landing]
#
# savvy_landing's script always re-applied the labels (it never had
# savvy-backend's first-occurrence-only gate), but the write was a bare
# `|| true` that was never read back. These tests lock the hardened shape:
# the labels are re-applied, through gh_retry.sh, on EVERY occurrence, with a
# REST read-back that is loud when needs-human-review is missing; the sticky
# comment and the tracking-issue log stay deduped; and the script always exits 0
# (it only annotates — it must never itself flip a block into a pass).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../gate_infra_escalate.sh"
FAILS=0

[ -f "$SCRIPT" ] || { echo "Error: $SCRIPT not found"; exit 1; }

assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILS=$((FAILS + 1)); fi
}

# A fake `gh` that distinguishes the call shapes this script makes:
#   - `gh api repos/.../issues/<pr>/labels --jq ...`  -> $SANDBOX/labels_now
#   - `gh api repos/.../issues/<pr>/comments --paginate ...` (sticky lookup)
#       -> $SANDBOX/existing_comment_id (empty = no sticky comment yet)
#   - `gh pr comment ... --body-file F` -> copies F to $SANDBOX/comment_posted
#   - `gh issue list ...` -> empty (no tracking issue yet)
#   - `gh issue edit ...` fails (exit 1) while $SANDBOX/edit_fail exists
#   - everything else is recorded in $CALL_LOG and exits 0.
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  CALL_LOG="$SANDBOX/calls.log"
  : > "$CALL_LOG"
  : > "$SANDBOX/existing_comment_id"
  printf 'gate-infra-error\nneeds-human-review\n' > "$SANDBOX/labels_now"
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<STUB
#!/bin/bash
echo "\$*" >> "$CALL_LOG"
if [ "\$1" = "api" ] && [[ "\$*" == *"/labels"* ]]; then
  cat "$SANDBOX/labels_now"; exit 0
fi
if [ "\$1" = "api" ] && [[ "\$*" == *"/comments"* ]] && [[ "\$*" != *"-X PATCH"* ]]; then
  cat "$SANDBOX/existing_comment_id"; exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "comment" ]; then
  cp "\$5" "$SANDBOX/comment_posted" 2>/dev/null; exit 0
fi
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  echo ""; exit 0
fi
if [ "\$1" = "issue" ] && [ "\$2" = "edit" ] && [ -f "$SANDBOX/edit_fail" ]; then
  echo "HTTP 502 Bad Gateway" >&2; exit 1
fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}
teardown_sandbox() { rm -rf "$SANDBOX"; }

run_script() {
  PATH="$SANDBOX/bin:$PATH" GITHUB_REPOSITORY="withSavvy/test" \
    bash "$SCRIPT" --pr 42 --check "review (Sonnet)" --detail "reviewer crash" \
    > "$SANDBOX/stdout.log" 2>&1
  echo $?
}

LABEL_CALL="--add-label gate-infra-error --add-label needs-human-review"

# --- 1. First occurrence: labels applied, repo passed explicitly ---
setup_sandbox
rc=$(run_script)
grep -q -- "issue edit 42 ${LABEL_CALL} --repo withSavvy/test" "$CALL_LOG" && L=1 || L=0
{ [ "$rc" = "0" ] && [ "$L" = "1" ]; } && c=0 || c=1
assert "first crash -> labels needs-human-review + gate-infra-error (explicit --repo), exit 0" "$c"
teardown_sandbox

# --- 2. EVERY occurrence labels: three consecutive crashes, sticky comment
# already present each time after the first -> labels applied 3 times, the
# sticky comment is PATCHed in place and never duplicated. ---
setup_sandbox
echo "999" > "$SANDBOX/existing_comment_id"
run_script >/dev/null; run_script >/dev/null; rc=$(run_script)
N=$(grep -c -- "$LABEL_CALL" "$CALL_LOG")
grep -q -- "pr comment" "$CALL_LOG" && NEWC=1 || NEWC=0
grep -q -- "-X PATCH repos/withSavvy/test/issues/comments/999" "$CALL_LOG" && P=1 || P=0
{ [ "$rc" = "0" ] && [ "$N" = "3" ] && [ "$NEWC" = "0" ] && [ "$P" = "1" ]; } && c=0 || c=1
assert "3 consecutive crashes -> labels applied each time (removal never sticks); comment PATCHed, not duplicated (applied=$N)" "$c"
teardown_sandbox

# --- 3. Read-back: label missing after a reported-success write -> loud ::error::, exit 0 ---
setup_sandbox
echo "gate-infra-error" > "$SANDBOX/labels_now"
rc=$(run_script)
grep -q -- "::error::.*backstop is missing" "$SANDBOX/stdout.log" && LOUD=1 || LOUD=0
{ [ "$rc" = "0" ] && [ "$LOUD" = "1" ]; } && c=0 || c=1
assert "read-back shows needs-human-review missing -> loud ::error::, still exits 0" "$c"
teardown_sandbox

# --- 4. Read-back present -> no spurious error ---
setup_sandbox
rc=$(run_script)
grep -q -- "backstop is missing" "$SANDBOX/stdout.log" && FE=1 || FE=0
{ [ "$rc" = "0" ] && [ "$FE" = "0" ]; } && c=0 || c=1
assert "read-back confirms needs-human-review -> no spurious backstop error" "$c"
teardown_sandbox

# --- 5. The label write fails persistently (retried) -> loud ::error::, exit 0 ---
setup_sandbox
touch "$SANDBOX/edit_fail"
rc=$(PATH="$SANDBOX/bin:$PATH" GITHUB_REPOSITORY="withSavvy/test" bash "$SCRIPT" --pr 42 --check "review (Sonnet)" --detail "x" > "$SANDBOX/stdout.log" 2>&1; echo $?)
N=$(grep -c "issue edit 42" "$CALL_LOG")
grep -q -- "::error::.*could not apply" "$SANDBOX/stdout.log" && LOUD=1 || LOUD=0
{ [ "$rc" = "0" ] && [ "$LOUD" = "1" ] && [ "$N" -ge 2 ]; } && c=0 || c=1
assert "label write fails after retries -> retried (>=2 attempts) and loud ::error::, still exits 0 (attempts=$N)" "$c"
teardown_sandbox

# --- 6. The posted sticky comment says removing labels does not release ---
setup_sandbox
rc=$(run_script)
{ [ "$rc" = "0" ] && grep -q "Removing labels does not release" "$SANDBOX/comment_posted" 2>/dev/null \
  && grep -q "human-approved" "$SANDBOX/comment_posted"; } && c=0 || c=1
assert "sticky comment: removing labels does not release (re-run or human-approved)" "$c"
teardown_sandbox

# --- 7. No --pr -> exits 0, no label calls ---
setup_sandbox
PATH="$SANDBOX/bin:$PATH" GITHUB_REPOSITORY="withSavvy/test" \
  bash "$SCRIPT" --check "review (Sonnet)" --detail "no pr context" > "$SANDBOX/stdout.log" 2>&1
rc=$?
grep -q -- "--add-label" "$CALL_LOG" && L=1 || L=0
{ [ "$rc" = "0" ] && [ "$L" = "0" ]; } && c=0 || c=1
assert "no --pr supplied -> exits 0, no label calls" "$c"
teardown_sandbox

# --- 8. Missing --check -> exits 0 (annotation helper never blocks on its own arg error) ---
setup_sandbox
if PATH="$SANDBOX/bin:$PATH" bash "$SCRIPT" --pr 42 > "$SANDBOX/stdout.log" 2>&1; then c=0; else c=1; fi
assert "missing --check -> exits 0" "$c"
teardown_sandbox

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

#!/bin/bash
# Fixture tests for gate_opus_verdict_route.sh — the terminal routing
# extracted from gate.yml's "Enforce Opus verdict (binding terminal gate)"
# step. [wo:fix-gate-opus-gate-fail-arm-must-add-needs-human-review-reject-
# verdicts-silently]
#
# THE negative test this order exists for: a FAIL verdict must add
# needs-human-review. Before this fix it silently exited 1 with NO label,
# and since opus-gate is intentionally not a required check, a genuine Opus
# REQUEST_CHANGES was mergeable with no human-visible trace (the 07-14
# "REJECT shipped anyway" incident, savvy-workspace#1459 item 1).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../gate_opus_verdict_route.sh"
FAILS=0

if [ ! -f "$SCRIPT" ]; then
  echo "Error: $SCRIPT not found"
  exit 1
fi

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  CALL_LOG="$SANDBOX/calls.log"
  : > "$CALL_LOG"
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<STUB
#!/bin/bash
echo "\$*" >> "$CALL_LOG"
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}

teardown_sandbox() {
  rm -rf "$SANDBOX"
}

run_script() {
  local verdict="$1"
  PATH="$SANDBOX/bin:$PATH" \
    bash "$SCRIPT" "$verdict" 123 "withSavvy/test" > "$SANDBOX/stdout.log" 2>&1
  echo $?
}

assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    FAILS=$((FAILS + 1))
  fi
}

# --- PASS verdict: gate green, exit 0, no label call ---
setup_sandbox
rc=$(run_script "PASS")
grep -q -- "--add-label" "$CALL_LOG" && LABELED=1 || LABELED=0
if [ "$rc" = "0" ] && [ "$LABELED" = "0" ]; then
  assert "PASS -> exit 0, no label call" 0
else
  assert "PASS -> exit 0, no label call (rc=$rc labeled=$LABELED)" 1
fi
teardown_sandbox

# --- THE regression under test: FAIL must label needs-human-review ---
setup_sandbox
rc=$(run_script "FAIL")
grep -q -- "--add-label needs-human-review" "$CALL_LOG" && LABELED=1 || LABELED=0
if [ "$rc" != "0" ] && [ "$LABELED" = "1" ]; then
  assert "FAIL -> blocks (exit!=0) AND labels needs-human-review (was silently unlabeled)" 0
else
  assert "FAIL -> blocks (exit!=0) AND labels needs-human-review (rc=$rc labeled=$LABELED)" 1
fi
teardown_sandbox

# --- No verdict emitted: pre-existing fail-closed behavior, must not regress ---
setup_sandbox
rc=$(run_script "")
grep -q -- "--add-label needs-human-review" "$CALL_LOG" && LABELED=1 || LABELED=0
if [ "$rc" != "0" ] && [ "$LABELED" = "1" ]; then
  assert "no verdict -> fail-closed AND labels needs-human-review (pre-existing, unchanged)" 0
else
  assert "no verdict -> fail-closed AND labels needs-human-review (rc=$rc labeled=$LABELED)" 1
fi
teardown_sandbox

# --- Garbage/unexpected verdict routes through the same fail-closed arm ---
setup_sandbox
rc=$(run_script "GARBAGE")
grep -q -- "--add-label needs-human-review" "$CALL_LOG" && LABELED=1 || LABELED=0
if [ "$rc" != "0" ] && [ "$LABELED" = "1" ]; then
  assert "garbage verdict -> fail-closed AND labeled" 0
else
  assert "garbage verdict -> fail-closed AND labeled (rc=$rc labeled=$LABELED)" 1
fi
teardown_sandbox

if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS test(s) FAILED"
  exit 1
fi
echo "ALL TESTS PASSED"

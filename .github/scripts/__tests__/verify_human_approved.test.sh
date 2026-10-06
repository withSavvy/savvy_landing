#!/bin/bash
# Tests for verify_human_approved.sh + the DRIFT guard against merge-guard.yml.
# [savvy-backend#1595 / tracking #1239] The override job and merge-guard must
# make the SAME "an allowlisted human added human-approved" decision.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../verify_human_approved.sh"
MERGE_GUARD="$TEST_DIR/../../workflows/merge-guard.yml"
FAILS=0

for f in "$SCRIPT" "$MERGE_GUARD"; do [ -f "$f" ] || { echo "Error: $f not found"; exit 1; }; done

assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILS=$((FAILS + 1)); fi
}

# Fake gh: `api .../issues/N/events ...` prints $SB/events (one actor login per
# line, oldest first — exactly what the real --jq would emit) or fails when
# $SB/events_fail exists.
setup() {
  SB="$(mktemp -d)"; mkdir -p "$SB/bin"; : > "$SB/events"
  cat > "$SB/bin/gh" <<STUB
#!/bin/bash
if [ "\$1" = "api" ] && [[ "\$2" == *"/issues/"*"/events" ]]; then
  [ -f "$SB/events_fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
  cat "$SB/events"; exit 0
fi
exit 0
STUB
  chmod +x "$SB/bin/gh"
}
teardown() { rm -rf "$SB"; }

# verify ALLOWLIST -> exit code; stdout in $SB/out
verify() {
  PATH="$SB/bin:$PATH" GITHUB_REPOSITORY="withSavvy/savvy_landing" PR_NUMBER=7 TIER_B_RELEASE_ACTORS="$1" \
    bash "$SCRIPT" > "$SB/out" 2>&1
  echo $?
}

echo "--- behaviour ---"
setup; echo "Sara3" > "$SB/events"; rc=$(verify "Sara3")
{ [ "$rc" = "0" ] && tail -n1 "$SB/out" | grep -qx 'adder=Sara3'; } && c=0 || c=1
assert "allowlisted human adder -> verified, prints adder=Sara3" "$c"; teardown

setup; echo "sara3" > "$SB/events"; rc=$(verify "Sara3, Other")
[ "$rc" = "0" ] && c=0 || c=1
assert "allowlist match is case-insensitive and tolerates comma+space lists" "$c"; teardown

setup; echo "claude[bot]" > "$SB/events"; rc=$(verify "claude[bot]")
[ "$rc" = "1" ] && c=0 || c=1
assert "[bot] adder -> NOT verified even if (mis)listed on the allowlist" "$c"; teardown

setup; echo "some-collaborator" > "$SB/events"; rc=$(verify "Sara3")
[ "$rc" = "1" ] && c=0 || c=1
assert "adder not on the allowlist -> NOT verified" "$c"; teardown

setup; touch "$SB/events_fail"; rc=$(verify "Sara3")
{ [ "$rc" = "1" ] && grep -q 'fail-closed' "$SB/out"; } && c=0 || c=1
assert "events API error -> NOT verified (fail-closed)" "$c"; teardown

setup; : > "$SB/events"; rc=$(verify "Sara3")
[ "$rc" = "1" ] && c=0 || c=1
assert "no matching labeled event -> NOT verified" "$c"; teardown

setup; printf 'Sara3\nsome-collaborator\n' > "$SB/events"; rc=$(verify "Sara3")
[ "$rc" = "1" ] && c=0 || c=1
assert "NEWEST labeled event governs: Sara3 then an outsider re-adds -> NOT verified" "$c"; teardown

setup; printf 'some-collaborator\nSara3\n' > "$SB/events"; rc=$(verify "Sara3")
[ "$rc" = "0" ] && c=0 || c=1
assert "NEWEST labeled event governs: outsider then Sara3 re-adds -> verified" "$c"; teardown

setup; echo "Sara3" > "$SB/events"
rc=$(PATH="$SB/bin:$PATH" GITHUB_REPOSITORY="withSavvy/savvy_landing" PR_NUMBER=7 env -u TIER_B_RELEASE_ACTORS bash "$SCRIPT" >/dev/null 2>&1; echo $?)
[ "$rc" = "1" ] && c=0 || c=1
assert "allowlist unset -> falls back to the repo OWNER login, matches no real actor -> NOT verified" "$c"; teardown

echo "--- DRIFT: merge-guard.yml inline copy == verify_human_approved.sh ---"
# Pull the function body out of each file (from its opening line to the first
# closing brace at the SAME indentation as the opening line), strip that
# indentation, and compare byte for byte.
extract_fn() {
  awk '
    !f && $0 ~ /^[[:space:]]*verified_human_approved_adder\(\) \{[[:space:]]*$/ {
      match($0, /^[[:space:]]*/); ind = RLENGTH; f = 1
    }
    f {
      line = $0
      if (length(line) >= ind) line = substr(line, ind + 1)
      print line
      if (substr($0, 1, ind + 1) ~ /^[[:space:]]*\}$/ && length($0) == ind + 1) exit
    }
  ' "$1"
}
A="$(extract_fn "$SCRIPT")"
B="$(extract_fn "$MERGE_GUARD")"
{ [ -n "$A" ] && [ -n "$B" ]; } && c=0 || c=1
assert "both files contain a verified_human_approved_adder() definition" "$c"
if [ "$A" = "$B" ]; then c=0; else c=1; diff <(printf '%s\n' "$A") <(printf '%s\n' "$B") | head -20; fi
assert "function bodies are byte-identical modulo indentation (edit BOTH merge-guard.yml and verify_human_approved.sh)" "$c"
grep -q 'export HUMAN_APPROVED_ADDER="\$login"' "$MERGE_GUARD" && c=0 || c=1
assert "merge-guard's copy carries the HUMAN_APPROVED_ADDER assignment too" "$c"
grep -q 'if has .human-approved.; then' "$MERGE_GUARD" && grep -q 'if verified_human_approved_adder; then' "$MERGE_GUARD" && c=0 || c=1
assert "merge-guard still calls verified_human_approved_adder before honouring the label" "$c"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

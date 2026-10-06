#!/bin/bash
# Tests for record_human_opus_override.sh — the SHA-bound human override of the
# `opus-verdict-recorded` status. [savvy-backend#1595 / tracking #1239]
# No POST unless: labeled human-approved + allowlisted non-bot adder verified
# live + label still present + live head == event head.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../record_human_opus_override.sh"
FAILS=0
SHA="0123456789abcdef0123456789abcdef01234567"
OTHER_SHA="fedcba9876543210fedcba9876543210fedcba98"

[ -f "$SCRIPT" ] || { echo "Error: $SCRIPT not found"; exit 1; }

assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILS=$((FAILS + 1)); fi
}

# Fake gh:
#   issues/N/events        -> $SB/events (actor logins, oldest first); fails if events_fail
#   pulls/N                -> $SB/pull   (line1 head sha, then label names); fails if pull_fail
#   commits/<sha>/statuses -> $SB/newest (description of the newest context status)
#   -X POST statuses/<sha> -> appended to $SB/posts; fails if post_fail
setup() {
  SB="$(mktemp -d)"; mkdir -p "$SB/bin"; : > "$SB/posts"
  printf 'Sara3\n' > "$SB/events"
  printf '%s\nhuman-approved\n' "$SHA" > "$SB/pull"
  : > "$SB/newest"
  cat > "$SB/bin/gh" <<STUB
#!/bin/bash
if [ "\$1" = "api" ] && [ "\$2" = "-X" ] && [ "\$3" = "POST" ]; then
  [ -f "$SB/post_fail" ] && { echo '{"message":"Server Error","status":"500"}' >&2; exit 1; }
  echo "\$*" >> "$SB/posts"
  # After the first POST the override becomes the newest status unless overtaken.
  [ -f "$SB/overtaken_once" ] || { [ -f "$SB/overtake" ] && { touch "$SB/overtaken_once"; echo "opus-gate infra-neutral (NO_EXEC_FILE_INFRA)" > "$SB/newest"; exit 0; }; }
  echo "human-override by Sara3 for 0123456" > "$SB/newest"
  exit 0
fi
if [ "\$1" = "api" ] && [[ "\$2" == *"/issues/"*"/events" ]]; then
  [ -f "$SB/events_fail" ] && { echo "HTTP 502" >&2; exit 1; }
  cat "$SB/events"; exit 0
fi
if [ "\$1" = "api" ] && [[ "\$2" == *"/pulls/"* ]]; then
  [ -f "$SB/pull_fail" ] && { echo '{"message":"boom","status":"500"}' >&2; exit 1; }
  cat "$SB/pull"; exit 0
fi
if [ "\$1" = "api" ] && [[ "\$2" == *"/statuses?per_page"* ]]; then cat "$SB/newest"; exit 0; fi
exit 0
STUB
  chmod +x "$SB/bin/gh"
}
teardown() { rm -rf "$SB"; }

# run [ACTION] [LABEL] [EVENT_SHA] [ALLOWLIST]
run() {
  PATH="$SB/bin:$PATH" GITHUB_REPOSITORY="withSavvy/savvy_landing" PR_NUMBER=7 \
    EVENT_ACTION="${1:-labeled}" EVENT_LABEL_NAME="${2:-human-approved}" EVENT_HEAD_SHA="${3:-$SHA}" \
    TIER_B_RELEASE_ACTORS="${4:-Sara3}" GATE_RETRY_SLEEP=0 \
    bash "$SCRIPT" > "$SB/out" 2>&1
  echo $?
}
posted() { [ -s "$SB/posts" ] && echo yes || echo no; }

echo "--- the happy path ---"
setup; rc=$(run)
{ [ "$rc" = "0" ] && grep -q "api -X POST repos/withSavvy/savvy_landing/statuses/${SHA}" "$SB/posts" \
  && grep -q -- '-f state=success' "$SB/posts" && grep -q -- '-f context=opus-verdict-recorded' "$SB/posts" \
  && grep -q -- '-f description=human-override by Sara3 for 0123456' "$SB/posts"; } && c=0 || c=1
assert "allowlisted adder, live head == event head, label present -> success 'human-override by Sara3 for 0123456' on the head SHA" "$c"; teardown

echo "--- every gate must hold ---"
setup; printf 'claude[bot]\n' > "$SB/events"; rc=$(run "labeled" "human-approved" "$SHA" "claude[bot]")
{ [ "$rc" = "0" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "[bot] adder -> NO post" "$c"; teardown

setup; printf 'some-collaborator\n' > "$SB/events"; rc=$(run)
{ [ "$rc" = "0" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "non-allowlisted adder -> NO post" "$c"; teardown

setup; touch "$SB/events_fail"; rc=$(run)
{ [ "$rc" = "0" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "events-API error -> NO post (fail-closed)" "$c"; teardown

setup; printf '%s\nhuman-approved\n' "$OTHER_SHA" > "$SB/pull"; rc=$(run)
{ [ "$rc" = "0" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "live head != event head (pushed after the label) -> NO post for either commit (SHA-bound)" "$c"; teardown

setup; printf '%s\nneeds-human-review\n' "$SHA" > "$SB/pull"; rc=$(run)
{ [ "$rc" = "0" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "label already removed again -> NO post (withdrawn approval is not an override)" "$c"; teardown

setup; touch "$SB/pull_fail"; rc=$(run)
{ [ "$rc" = "1" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "live PR read fails -> exit 1, NO post" "$c"; teardown

setup; rc=$(run "unlabeled" "human-approved")
{ [ "$rc" = "0" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "unlabeled human-approved -> no-op (removing labels never releases, and never revokes silently either)" "$c"; teardown

setup; rc=$(run "labeled" "needs-human-review")
{ [ "$rc" = "0" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "labeled with some OTHER label -> no-op" "$c"; teardown

setup; rc=$(run "labeled" "human-approved" "notasha")
{ [ "$rc" = "1" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "malformed event sha -> exit 1, NO post" "$c"; teardown

setup; touch "$SB/post_fail"; rc=$(run)
[ "$rc" = "1" ] && c=0 || c=1
assert "POST fails after retries -> exit 1" "$c"; teardown

echo "--- race with the gate recorder ---"
setup; touch "$SB/overtake"; rc=$(run)
N=$(wc -l < "$SB/posts" | tr -d ' ')
{ [ "$rc" = "0" ] && [ "$N" = "2" ]; } && c=0 || c=1
assert "a later recorder status overtakes the override -> re-posted once (2 POSTs)" "$c"; teardown

echo "--- description hygiene ---"
setup; printf 'bad;login\n' > "$SB/events"; rc=$(run "labeled" "human-approved" "$SHA" 'bad;login')
{ [ "$rc" = "1" ] && [ "$(posted)" = no ]; } && c=0 || c=1
assert "an adder login that is not a plain GitHub login is never put into a status description" "$c"; teardown

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

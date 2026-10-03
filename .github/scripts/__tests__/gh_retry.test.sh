#!/bin/bash
# Tests for gh_retry.sh's rate-limit wait. [savvy-backend#1595 / tracking #1239]
# A 403/429 "rate limit exceeded" must wait >= GH_RETRY_RATE_LIMIT_SLEEP (60s by
# default) plus jitter, not the short fixed --sleep; every other failure keeps
# the fixed sleep. `sleep` is replaced by a stub that records its argument, so
# nothing here actually waits.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../gh_retry.sh"
FAILS=0
[ -f "$SCRIPT" ] || { echo "Error: $SCRIPT not found"; exit 1; }

assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILS=$((FAILS + 1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sleep" <<STUB
#!/bin/bash
echo "\$1" >> "$TMP/sleeps"
STUB
# fake gh: fails with \$GH_MSG until the call count reaches \$GH_OK_AT, then succeeds.
cat > "$TMP/bin/gh" <<STUB
#!/bin/bash
n=\$(cat "$TMP/n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$TMP/n"
if [ "\$n" -ge "\${GH_OK_AT:-99}" ]; then echo "ok-body"; exit 0; fi
echo "\${GH_MSG:-boom}" >&2
exit 1
STUB
chmod +x "$TMP/bin/sleep" "$TMP/bin/gh"

# run MSG OK_AT [env...] -> exit code; sleeps in $TMP/sleeps, stdout in $TMP/out
run() {
  local msg="$1" ok_at="$2"; shift 2
  : > "$TMP/sleeps"; rm -f "$TMP/n"
  env PATH="$TMP/bin:$PATH" GH_MSG="$msg" GH_OK_AT="$ok_at" "$@" \
    bash "$SCRIPT" --retries 2 --sleep 2 -- gh api x > "$TMP/out" 2>/dev/null
  echo $?
}
RL='gh: API rate limit exceeded for installation ID 146412380. (HTTP 403)'

rc=$(run "$RL" 2)
s=$(head -n1 "$TMP/sleeps")
{ [ "$rc" = "0" ] && [ "${s:-0}" -ge 60 ] && [ "${s:-0}" -le 75 ]; } && c=0 || c=1
assert "installation 403 rate limit -> waits 60..75s (not the 2s --sleep), then succeeds (waited '$s')" "$c"

rc=$(run 'gh: You have exceeded a secondary rate limit. (HTTP 403)' 2)
s=$(head -n1 "$TMP/sleeps")
{ [ "$rc" = "0" ] && [ "${s:-0}" -ge 60 ]; } && c=0 || c=1
assert "secondary rate limit 403 -> waits >= 60s (waited '$s')" "$c"

rc=$(run 'gh: API rate limit exceeded (HTTP 429)' 2)
s=$(head -n1 "$TMP/sleeps")
{ [ "$rc" = "0" ] && [ "${s:-0}" -ge 60 ]; } && c=0 || c=1
assert "429 rate limit -> waits >= 60s (waited '$s')" "$c"

# jitter: across many runs the wait is always inside [60,75] and not constant
seen=""; ok=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  run "$RL" 2 >/dev/null; w=$(head -n1 "$TMP/sleeps")
  { [ "$w" -ge 60 ] && [ "$w" -le 75 ]; } || ok=1
  seen="$seen $w"
done
distinct=$(printf '%s\n' $seen | sort -u | wc -l | tr -d ' ')
{ [ "$ok" = "0" ] && [ "$distinct" -gt 1 ]; } && c=0 || c=1
assert "jitter keeps every wait in [60,75] and varies across runs (distinct=$distinct)" "$c"

rc=$(run "$RL" 99)
n_sleeps=$(wc -l < "$TMP/sleeps" | tr -d ' ')
{ [ "$rc" = "2" ] && [ "$n_sleeps" = "2" ] && [ "$(sort -n "$TMP/sleeps" | head -n1)" -ge 60 ]; } && c=0 || c=1
assert "persistent rate limit -> every retry waits >= 60s, then exit 2 (infra escalation)" "$c"

rc=$(run 'gh: Server Error (HTTP 502)' 2)
s=$(head -n1 "$TMP/sleeps")
{ [ "$rc" = "0" ] && [ "$s" = "2" ]; } && c=0 || c=1
assert "a 502 keeps the short fixed --sleep (waited '$s')" "$c"

rc=$(run 'gh: Resource not accessible by integration (HTTP 403)' 2)
s=$(head -n1 "$TMP/sleeps")
{ [ "$rc" = "0" ] && [ "$s" = "2" ]; } && c=0 || c=1
assert "a 403 WITHOUT 'rate limit' keeps the short --sleep (waited '$s')" "$c"

rc=$(run 'gh: could not resolve host: rate limit proxy' 2)
s=$(head -n1 "$TMP/sleeps")
{ [ "$rc" = "0" ] && [ "$s" = "2" ]; } && c=0 || c=1
assert "'rate limit' text without a 403/429 keeps the short --sleep (waited '$s')" "$c"

rc=$(run "$RL" 2 GH_RETRY_RATE_LIMIT_SLEEP=0 GH_RETRY_RATE_LIMIT_JITTER=0)
s=$(head -n1 "$TMP/sleeps")
{ [ "$rc" = "0" ] && [ "$s" = "2" ]; } && c=0 || c=1
assert "env override can shrink the rate-limit wait but never below --sleep (waited '$s')" "$c"

rc=$(run "$RL" 2 GH_RETRY_RATE_LIMIT_SLEEP=abc GH_RETRY_RATE_LIMIT_JITTER=-1)
s=$(head -n1 "$TMP/sleeps")
{ [ "$rc" = "0" ] && [ "${s:-0}" -ge 60 ]; } && c=0 || c=1
assert "malformed env override falls back to the 60s default (waited '$s')" "$c"

rc=$(run "$RL" 1)
s=$(wc -c < "$TMP/sleeps" | tr -d ' ')
{ [ "$rc" = "0" ] && [ "$s" = "0" ] && grep -q ok-body "$TMP/out"; } && c=0 || c=1
assert "first-try success: no sleep, body echoed" "$c"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

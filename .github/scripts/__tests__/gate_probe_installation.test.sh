#!/bin/bash
# Tests for gate_probe_installation.sh — the live structural probe feeding
# gate_check_ran.py's INSTALLATION_RATE_LIMIT_INFRA arm.
# [savvy-backend#1595 / tracking #1239, ported to savvy_landing]
# Diagnostic-only: exit 0 always, never gates the reviewer.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PROBE="$TEST_DIR/../gate_probe_installation.sh"
CHECK="$TEST_DIR/../gate_check_ran.py"
FAILS=0

assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILS=$((FAILS + 1)); fi
}

for f in "$INSTALL_PROBE" "$CHECK"; do
  [ -f "$f" ] || { echo "Error: $f not found"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# A fake `gh` replaying a canned `gh api -i` response from $GH_REPLY_FILE.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_CALL_LOG"
echo "token=${GH_TOKEN:-}" >> "$GH_CALL_LOG"
if [ -f "$GH_REPLY_FILE" ]; then cat "$GH_REPLY_FILE"; fi
exit "${GH_EXIT:-0}"
STUB
chmod +x "$TMP/bin/gh"

reply_403() {
  printf 'HTTP/2.0 403 Forbidden\r\nContent-Type: application/json; charset=utf-8\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: 1759447320\r\nX-Ratelimit-Resource: core\r\n\r\n{"message":"API rate limit exceeded for installation ID 146412380.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}\n' > "$TMP/reply"
}
reply_200() {
  printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 4731\r\nX-Ratelimit-Reset: 1759447320\r\n\r\n{"login":"Sara3"}\n' > "$TMP/reply"
}

run_install() { # ACTOR TOKEN
  : > "$TMP/calls"
  GH_CALL_LOG="$TMP/calls" GH_REPLY_FILE="$TMP/reply" GITHUB_ACTOR="$1" APP_TOKEN="$2" PATH="$TMP/bin:$PATH" \
    bash "$INSTALL_PROBE" > "$TMP/probe_out" 2>/dev/null
  echo $?
}

reply_403
rc=$(run_install Sara3 app-token-xyz)
{ [ "$rc" = "0" ] && grep -qx 'installation_probe_status=403' "$TMP/probe_out" \
  && grep -qx 'installation_probe_remaining=0' "$TMP/probe_out" \
  && grep -qx 'installation_probe_reset_epoch=1759447320' "$TMP/probe_out" \
  && grep -qx 'installation_probe_message=API rate limit exceeded for installation ID 146412380.' "$TMP/probe_out"; } && c=0 || c=1
assert "403 with GitHub's installation rate-limit message -> status/remaining/reset/message captured" "$c"
grep -q 'api -i /users/Sara3' "$TMP/calls" && grep -qx 'token=app-token-xyz' "$TMP/calls" && c=0 || c=1
assert "probe calls GET /users/<actor> with the APP token, not another credential" "$c"

# End to end with the classifier: probe output + crash evidence -> the token.
{ printf 'schema=gate-reviewer-diag-v3\nfix_pass_outcome=failure\nreview_only_pass_outcome=skipped\n'; cat "$TMP/probe_out"; } > "$TMP/diag"
[ "$(python3 "$CHECK" "" "" "" "false" "$TMP/diag")" = "INSTALLATION_RATE_LIMIT_INFRA" ] && c=0 || c=1
assert "probe output piped into the diag file classifies as INSTALLATION_RATE_LIMIT_INFRA end to end" "$c"

reply_200
rc=$(run_install Sara3 app-token-xyz)
{ [ "$rc" = "0" ] && grep -qx 'installation_probe_status=200' "$TMP/probe_out" && grep -qx 'installation_probe_message=' "$TMP/probe_out"; } && c=0 || c=1
assert "200 -> status=200, empty message (stays NO_EXEC_FILE_INFRA downstream)" "$c"
{ printf 'schema=gate-reviewer-diag-v3\nfix_pass_outcome=failure\nreview_only_pass_outcome=skipped\n'; cat "$TMP/probe_out"; } > "$TMP/diag"
[ "$(python3 "$CHECK" "" "" "" "false" "$TMP/diag")" = "NO_EXEC_FILE_INFRA" ] && c=0 || c=1
assert "200 probe + crash -> NO_EXEC_FILE_INFRA end to end" "$c"

reply_403
rc=$(run_install Sara3 "")
{ [ "$rc" = "0" ] && grep -qx 'installation_probe_status=skipped' "$TMP/probe_out" && [ ! -s "$TMP/calls" ]; } && c=0 || c=1
assert "no App token -> skipped, NO API call made (a PAT/GITHUB_TOKEN probe says nothing about the installation bucket)" "$c"

rc=$(run_install 'x; rm -rf /' app-token-xyz)
{ [ "$rc" = "0" ] && grep -qx 'installation_probe_status=skipped' "$TMP/probe_out" && [ ! -s "$TMP/calls" ]; } && c=0 || c=1
assert "malformed actor login is never interpolated into the API path -> skipped" "$c"

rc=$(run_install 'dependabot[bot]' app-token-xyz)
grep -q 'api -i /users/dependabot\[bot\]' "$TMP/calls" && c=0 || c=1
assert "[bot] actor logins are accepted" "$c"

: > "$TMP/reply"
rc=$(run_install Sara3 app-token-xyz)
{ [ "$rc" = "0" ] && grep -qx 'installation_probe_status=error' "$TMP/probe_out"; } && c=0 || c=1
assert "gh produced no HTTP response (network down) -> status=error, exit 0" "$c"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

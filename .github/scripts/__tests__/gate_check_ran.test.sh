#!/bin/bash
# Matrix test for gate_check_ran.py — invokes the SAME script gate.yml's
# reviewer-classifier steps invoke. Locks the arm-B no-execution-file split
# [savvy-backend#1595 / tracking #1239, ported to savvy_landing]:
#   file ABSENT + structural action-step crash evidence -> NO_EXEC_FILE_INFRA
#   ... and a live installation probe saying "rate limit exceeded for
#   installation" -> INSTALLATION_RATE_LIMIT_INFRA;
#   undeterminable, or present-but-corrupt -> FAIL_HARD unchanged; never PASS.
# Plus the pre-existing arms (PASS / ROUTE_HUMAN / FAIL_HARD / AUTH_FAIL), which
# had no test in this repo.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$DIR/.." && pwd)/gate_check_ran.py"
[ -f "$SCRIPT" ] || { echo "Error: $SCRIPT not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# assert_token DESC CONCLUSION SKIPPED EXEC_JSON EDITS_WORKFLOWS EXPECTED [DIAG]
# EXEC_JSON "" -> no execution file path at all; "@ABSENT" -> a path that does
# not exist; "@EMPTY" -> a present-but-empty file. DIAG (optional): contents of
# the diagnostics file gate.yml's capture step writes; omitted -> argv[5]="".
assert_token() {
  local desc="$1" conclusion="$2" skipped="$3" exec_json="$4" edits="$5" want="$6" diag="${7:-}"
  local file="" diag_file="" got
  case "$exec_json" in
    "")       file="" ;;
    @ABSENT)  file="$TMP/never-written.json" ;;
    @EMPTY)   file="$TMP/empty.json"; : > "$file" ;;
    *)        file="$TMP/exec.json"; printf '%s' "$exec_json" > "$file" ;;
  esac
  if [ -n "$diag" ]; then
    diag_file="$TMP/diag.txt"
    printf '%s\n' "$diag" > "$diag_file"
  fi
  got=$(python3 "$SCRIPT" "$conclusion" "$skipped" "$file" "$edits" "$diag_file")
  if [ "$got" = "$want" ]; then echo "PASS: $desc"; else echo "FAIL: $desc — got $got, want $want"; FAILS=$((FAILS + 1)); fi
}

CLEAN='[{"type":"result","is_error":false,"result":"looks good"}]'
AUTH='[{"type":"result","is_error":true,"error":"authentication_failed"}]'
MAXTURNS='[{"type":"result","is_error":true,"subtype":"error_max_turns"}]'
OTHER_ERR='[{"type":"result","is_error":true,"subtype":"error_during_execution"}]'

echo "--- pre-existing arms ---"
assert_token "clean result -> PASS"                         "" "" "$CLEAN"    false PASS
assert_token "workflow edits -> ROUTE_HUMAN (never PASS)"   "" "" "$CLEAN"    true  ROUTE_HUMAN
assert_token "401 -> AUTH_FAIL"                             "" "" "$AUTH"     false AUTH_FAIL
assert_token "max-turns -> ROUTE_HUMAN"                     "" "" "$MAXTURNS" false ROUTE_HUMAN
assert_token "other is_error -> FAIL_HARD"                  "" "" "$OTHER_ERR" false FAIL_HARD
assert_token "non-success conclusion -> FAIL_HARD"          "failure" "" "$CLEAN" false FAIL_HARD

echo "--- arm B: no execution file ---"
CRASH='schema=gate-reviewer-diag-v3
fix_pass_outcome=failure
review_only_pass_outcome=skipped'
assert_token "no exec file, no diag file -> FAIL_HARD (undeterminable)"        "" "" ""        false FAIL_HARD
assert_token "absent exec file, no diag file -> FAIL_HARD"                     "" "" "@ABSENT" false FAIL_HARD
assert_token "absent exec file + fix pass crashed -> NO_EXEC_FILE_INFRA"       "" "" "@ABSENT" false NO_EXEC_FILE_INFRA "$CRASH"
assert_token "no exec path + review-only pass crashed -> NO_EXEC_FILE_INFRA"   "" "" ""        false NO_EXEC_FILE_INFRA \
  "$(printf 'fix_pass_outcome=skipped\nreview_only_pass_outcome=failure')"
assert_token "no crash evidence (both skipped) -> FAIL_HARD, never infra"      "" "" "@ABSENT" false FAIL_HARD \
  "$(printf 'fix_pass_outcome=skipped\nreview_only_pass_outcome=skipped')"
assert_token "present-but-empty exec file + crash evidence -> FAIL_HARD (half-written is not evidence)" "" "" "@EMPTY" false FAIL_HARD "$CRASH"
assert_token "a 'failure' string elsewhere in the diag file does not count"    "" "" "@ABSENT" false FAIL_HARD \
  "$(printf 'note=fix_pass_outcome=failure\nfix_pass_outcome=skipped')"
assert_token "workflow edits still ROUTE_HUMAN ahead of the crash arm"         "" "" "@ABSENT" true  ROUTE_HUMAN "$CRASH"

echo "--- installation rate-limit probe (the 32/34 #1239 class) ---"
assert_token "probe 403 'rate limit exceeded for installation' + crash -> INSTALLATION_RATE_LIMIT_INFRA" "" "" "@ABSENT" false INSTALLATION_RATE_LIMIT_INFRA \
  "$(printf '%s\ninstallation_probe_status=403\ninstallation_probe_remaining=0\ninstallation_probe_message=API rate limit exceeded for installation ID 146412380.' "$CRASH")"
assert_token "probe 429 with the same message -> INSTALLATION_RATE_LIMIT_INFRA" "" "" "@ABSENT" false INSTALLATION_RATE_LIMIT_INFRA \
  "$(printf '%s\ninstallation_probe_status=429\ninstallation_probe_message=API rate limit exceeded for installation ID 1.' "$CRASH")"
# [savvy-backend#1595 goal 3] remaining>0 = throttle with budget left; 0 = drained.
assert_token "probe 403 installation message, remaining>0 -> INSTALLATION_REST_THROTTLE_INFRA" "" "" "@ABSENT" false INSTALLATION_REST_THROTTLE_INFRA \
  "$(printf '%s\ninstallation_probe_status=403\ninstallation_probe_remaining=4731\ninstallation_probe_resource=core\ninstallation_probe_message=API rate limit exceeded for installation ID 146412380.' "$CRASH")"
assert_token "probe 403 installation message, remaining=1 -> INSTALLATION_REST_THROTTLE_INFRA" "" "" "@ABSENT" false INSTALLATION_REST_THROTTLE_INFRA \
  "$(printf '%s\ninstallation_probe_status=403\ninstallation_probe_remaining=1\ninstallation_probe_message=API rate limit exceeded for installation ID 1.' "$CRASH")"
assert_token "probe 429 installation message, remaining>0 -> INSTALLATION_REST_THROTTLE_INFRA" "" "" "@ABSENT" false INSTALLATION_REST_THROTTLE_INFRA \
  "$(printf '%s\ninstallation_probe_status=429\ninstallation_probe_remaining=12\ninstallation_probe_message=API rate limit exceeded for installation ID 1.' "$CRASH")"
assert_token "probe 403 installation message, remaining=0 -> INSTALLATION_RATE_LIMIT_INFRA" "" "" "@ABSENT" false INSTALLATION_RATE_LIMIT_INFRA \
  "$(printf '%s\ninstallation_probe_status=403\ninstallation_probe_remaining=0\ninstallation_probe_message=API rate limit exceeded for installation ID 1.' "$CRASH")"
assert_token "probe 403 installation message, remaining non-numeric -> INSTALLATION_RATE_LIMIT_INFRA (conservative)" "" "" "@ABSENT" false INSTALLATION_RATE_LIMIT_INFRA \
  "$(printf '%s\ninstallation_probe_status=403\ninstallation_probe_remaining=lots\ninstallation_probe_message=API rate limit exceeded for installation ID 1.' "$CRASH")"
assert_token "probe 403 installation message, remaining negative -> INSTALLATION_RATE_LIMIT_INFRA" "" "" "@ABSENT" false INSTALLATION_RATE_LIMIT_INFRA \
  "$(printf '%s\ninstallation_probe_status=403\ninstallation_probe_remaining=-5\ninstallation_probe_message=API rate limit exceeded for installation ID 1.' "$CRASH")"
assert_token "remaining>0 but UNRELATED 403 message -> NO_EXEC_FILE_INFRA (throttle needs GitHub's own message)" "" "" "@ABSENT" false NO_EXEC_FILE_INFRA \
  "$(printf '%s\ninstallation_probe_status=403\ninstallation_probe_remaining=4000\ninstallation_probe_message=Resource not accessible by integration' "$CRASH")"
assert_token "remaining>0, 200 probe -> NO_EXEC_FILE_INFRA (budget alone is not a rate limit)" "" "" "@ABSENT" false NO_EXEC_FILE_INFRA \
  "$(printf '%s\ninstallation_probe_status=200\ninstallation_probe_remaining=4731\ninstallation_probe_message=' "$CRASH")"
assert_token "probe 200 + crash -> stays NO_EXEC_FILE_INFRA" "" "" "@ABSENT" false NO_EXEC_FILE_INFRA \
  "$(printf '%s\ninstallation_probe_status=200\ninstallation_probe_message=' "$CRASH")"
assert_token "probe 403 with an UNRELATED message -> NO_EXEC_FILE_INFRA" "" "" "@ABSENT" false NO_EXEC_FILE_INFRA \
  "$(printf '%s\ninstallation_probe_status=403\ninstallation_probe_message=Resource not accessible by integration' "$CRASH")"
assert_token "probe 403 rate-limit message but NO crash evidence -> FAIL_HARD (never manufactured)" "" "" "@ABSENT" false FAIL_HARD \
  "$(printf 'fix_pass_outcome=skipped\nreview_only_pass_outcome=skipped\ninstallation_probe_status=403\ninstallation_probe_message=API rate limit exceeded for installation ID 1.')"
assert_token "probe skipped (no App token) + crash -> NO_EXEC_FILE_INFRA" "" "" "@ABSENT" false NO_EXEC_FILE_INFRA \
  "$(printf '%s\ninstallation_probe_status=skipped' "$CRASH")"
assert_token "a real result event ignores the diag file entirely (clean -> PASS)" "" "" "$CLEAN" false PASS \
  "$(printf '%s\ninstallation_probe_status=403\ninstallation_probe_message=API rate limit exceeded for installation ID 1.' "$CRASH")"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

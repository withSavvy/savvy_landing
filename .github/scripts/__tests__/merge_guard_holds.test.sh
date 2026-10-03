#!/bin/bash
# Behavioural test for merge-guard.yml's hold-label check.
#
# ---------------------------------------------------------------------------
# WHY THIS WAS REWRITTEN (2026-08-13)
#
# The previous version of this file did NOT test merge-guard.yml. It pasted a
# copy of the workflow's grep into a local shell function and asserted against
# the copy:
#
#     # check_labels_json mirrors the exact line from merge-guard.yml:
#     check_labels_json() { echo "$1" | grep -E -i '"(do-not-merge|...)"'; }
#
# A test that re-implements its subject cannot detect the subject changing —
# only itself changing. When merge-guard.yml was replaced with the
# live-API-read implementation (new regex, new `human-approved` override, new
# fail-closed path), this file kept printing ALL TESTS PASSED while asserting
# behaviour the workflow no longer had, and its header still claimed
# "merge-guard.yml ... is UNCHANGED ... it already reads labels from its own
# triggering event ($GITHUB_EVENT_PATH)" — false on every clause.
#
# That is the exact failure mode catalogued in
# savvy-workspace/.claude/docs/verification-traps.md: a check that reports
# success without verifying anything. A green run of the old file was worth
# nothing.
#
# This version EXTRACTS the real `run:` block out of merge-guard.yml and
# executes it against a stubbed `gh`. It cannot silently drift, because there
# is only one copy of the logic and this test runs it.
# ---------------------------------------------------------------------------
#
# EXTENDED 2026-10-02 [savvy-backend#1595 / tracking #1239, ported from savvy-backend's
# 2026-09-21 [wo:p0-merge-guard-accepts-human-approved-with-no-check-on-who-added-it]]
#
# `human-approved` used to be accepted on PRESENCE alone (savvy_landing too, until
# this change). savvy-backend PR #1148 showed that is forgeable by anyone who can call the labeling API
# under an allowlisted login (a cloud session holding Sara's `Sara3` PAT).
# The fixed script now reads WHO added the label (via the issue-events API)
# and only honors it when that actor is on `TIER_B_RELEASE_ACTORS`. The stub
# `gh` below now answers TWO distinct API calls: the labels read
# (`.../pulls/...`) and the events read (`.../issues/.../events`), each
# independently controllable so a test can assert the adder-check in
# isolation from the label-presence check.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_YML="$HERE/../../workflows/merge-guard.yml"
FAILS=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

if [ ! -f "$GUARD_YML" ]; then
  echo "FAIL: merge-guard.yml not found at $GUARD_YML"
  exit 1
fi

# Extract the single `run: |` block and dedent it. No YAML parser needed (and
# none is guaranteed on the runner): take every line after `run: |` that is
# blank or indented deeper than the `run:` key itself.
GUARD_SH="$TMPROOT/guard.sh"
awk '
  /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ && !seen {
    seen = 1
    match($0, /^[[:space:]]*/)
    key_indent = RLENGTH
    next
  }
  seen == 1 {
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    match($0, /^[[:space:]]*/)
    if (RLENGTH <= key_indent) { seen = 2; next }
    if (body_indent == 0) { body_indent = RLENGTH }
    print substr($0, body_indent + 1)
  }
' "$GUARD_YML" > "$GUARD_SH"

if [ ! -s "$GUARD_SH" ]; then
  echo "FAIL: could not extract the run: block from merge-guard.yml"
  exit 1
fi
if ! bash -n "$GUARD_SH"; then
  echo "FAIL: extracted merge-guard script is not valid bash"
  exit 1
fi
# Guard against extracting the wrong block / a stub: the real check must read
# labels AND verify the human-approved adder. Without this, a botched
# extraction would make every case below "pass" by running an empty script
# that exits 0, or silently run against pre-fix logic forever.
if ! grep -q 'labels' "$GUARD_SH"; then
  echo "FAIL: extracted script never mentions labels — extraction is wrong"
  exit 1
fi
if ! grep -q 'verified_human_approved_adder' "$GUARD_SH"; then
  echo "FAIL: extracted script has no verified_human_approved_adder — extraction is wrong or the fix regressed"
  exit 1
fi

# run_guard <newline-separated-labels | FAIL> <newline-separated actor logins
#   for each 'labeled human-approved' event, oldest first | FAIL> [allowlist]
#   [newline-separated changed-file paths | FAIL]
# -> echoes the guard's exit code. Also writes the guard's combined
#   stdout+stderr to $TMPROOT/last_output for expect_contains() below, instead
#   of discarding it, so a case can assert on error TEXT and not just exit
#   code (needed to prove which of two blocking checks actually fired).
#
# `files` defaults to a harmless non-CI-surface path so every pre-existing
# call site (none of which pass a 5th arg) keeps exercising the label logic
# exactly as before — the new CI-surface file check never fires unless a case
# opts in by passing one.
#
# The events/files stubs emit plain lines directly, standing in for what the
# real `gh api ... --jq '...'` calls would already have filtered down to — the
# guard script never sees raw JSON either way.
#
# SHA-BINDING (2026-10-02 review fix): the guard also reads three more things to
# decide whether a verified `human-approved` is still CURRENT for the live head
# (human_approval_is_current_for_head): the label's `created_at` (events call
# with a created_at --jq), the live head sha (pulls call with a head.sha --jq),
# and the earliest workflow-run `created_at` for that sha (actions/runs call).
# Optional 7th/8th args set the label time / first run time; "FAIL" makes that
# call error. Defaults make the approval current (label newer than the first run).
run_guard() {
  local labels="$1" events_actors="${2:-}" allowlist="${3:-Sara3}" files="${4:-README.md}"
  local approved_at="${5:-2026-10-02T12:00:00Z}" first_run="${6:-2026-10-02T11:00:00Z}"
  local bindir="$TMPROOT/bin"
  rm -rf "$bindir"; mkdir -p "$bindir"

  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'mode=""'
    printf '%s\n' 'args="$*"'
    printf '%s\n' 'case "$args" in'
    printf '%s\n' '  *actions/runs*) mode=runs ;;'
    printf '%s\n' '  */issues/*/events*created_at*) mode=eventtime ;;'
    printf '%s\n' '  */issues/*/events*) mode=events ;;'
    printf '%s\n' '  */pulls/*/files*) mode=files ;;'
    printf '%s\n' '  */pulls/*head.sha*) mode=head ;;'
    printf '%s\n' '  */pulls/*) mode=labels ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'if [ "$mode" = runs ]; then'
    if [ "$first_run" = "FAIL" ]; then
      printf '%s\n' '  echo "HTTP 502 Bad Gateway" >&2; exit 1'
    else
      printf '%s\n' "  printf '%s\\n' '$first_run' '2026-10-02T11:30:00Z'"
    fi
    printf '%s\n' 'elif [ "$mode" = eventtime ]; then'
    if [ "$approved_at" = "FAIL" ]; then
      printf '%s\n' '  echo "HTTP 502 Bad Gateway" >&2; exit 1'
    else
      printf '%s\n' "  printf '%s\\n' '$approved_at'"
    fi
    printf '%s\n' 'elif [ "$mode" = head ]; then'
    printf '%s\n' "  echo 0123456789abcdef0123456789abcdef01234567"
    printf '%s\n' 'elif [ "$mode" = labels ]; then'
    if [ "$labels" = "FAIL" ]; then
      printf '%s\n' '  echo "HTTP 502 Bad Gateway" >&2; exit 1'
    else
      printf '%s\n' "  cat <<'STUBLABELS'"
      printf '%s\n' "$labels"
      printf '%s\n' 'STUBLABELS'
    fi
    printf '%s\n' 'elif [ "$mode" = files ]; then'
    if [ "$files" = "FAIL" ]; then
      printf '%s\n' '  echo "HTTP 502 Bad Gateway" >&2; exit 1'
    else
      printf '%s\n' "  cat <<'STUBFILES'"
      printf '%s\n' "$files"
      printf '%s\n' 'STUBFILES'
    fi
    printf '%s\n' 'elif [ "$mode" = events ]; then'
    if [ "$events_actors" = "FAIL" ]; then
      printf '%s\n' '  echo "HTTP 502 Bad Gateway" >&2; exit 1'
    else
      printf '%s\n' "  cat <<'STUBEVENTS'"
      printf '%s\n' "$events_actors"
      printf '%s\n' 'STUBEVENTS'
    fi
    printf '%s\n' 'else'
    printf '%s\n' '  echo "unstubbed gh call: $*" >&2; exit 1'
    printf '%s\n' 'fi'
  } > "$bindir/gh"
  chmod +x "$bindir/gh"

  PATH="$bindir:$PATH" \
  GITHUB_REPOSITORY="withSavvy/savvy_landing" \
  PR_NUMBER="1" \
  TIER_B_RELEASE_ACTORS="$allowlist" \
  bash "$GUARD_SH" >"$TMPROOT/last_output" 2>&1
  echo $?
}

expect() {
  local desc="$1" labels="$2" events_actors="$3" want="$4" allowlist="${5:-Sara3}" files="${6:-README.md}"
  local approved_at="${7:-2026-10-02T12:00:00Z}" first_run="${8:-2026-10-02T11:00:00Z}"
  local got; got="$(run_guard "$labels" "$events_actors" "$allowlist" "$files" "$approved_at" "$first_run")"
  if [ "$got" = "$want" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (wanted exit $want, got $got)"
    FAILS=$((FAILS + 1))
  fi
}

# expect_contains: re-runs the guard (same args as an expect() case, minus
# `want`) and asserts a substring appears in its combined output. Used to
# prove WHICH message fired, not just that something exited non-zero.
expect_contains() {
  local desc="$1" labels="$2" events_actors="$3" allowlist="$4" files="$5" want_substring="$6"
  local approved_at="${7:-2026-10-02T12:00:00Z}" first_run="${8:-2026-10-02T11:00:00Z}"
  run_guard "$labels" "$events_actors" "$allowlist" "$files" "$approved_at" "$first_run" >/dev/null
  if grep -qF "$want_substring" "$TMPROOT/last_output"; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (output missing: $want_substring)"
    FAILS=$((FAILS + 1))
  fi
}

# --- absolute holds: block, and are NOT overridable ------------------------
expect "do-not-merge -> blocks"                        "do-not-merge"                             ""       1
expect "hold -> blocks (the #728 near-miss)"           "hold"                                     ""       1
expect "do-not-merge + human-approved -> still blocks" "$(printf 'do-not-merge\nhuman-approved')" "Sara3"  1
expect "hold + human-approved -> still blocks"         "$(printf 'hold\nhuman-approved')"         "Sara3"  1

# --- advisory holds: block, but a VERIFIED human-approved overrides --------
expect "needs-human-review -> blocks"                  "needs-human-review"                       ""       1
expect "reviewing -> blocks"                           "reviewing"                                ""       1
expect "human-approved by allowlisted actor overrides needs-human-review" \
       "$(printf 'needs-human-review\nhuman-approved')" "Sara3" 0
expect "human-approved by allowlisted actor overrides reviewing" \
       "$(printf 'reviewing\nhuman-approved')"          "Sara3" 0

# --- clean / matching precision -------------------------------------------
expect "clean labels -> clears"                        "enhancement"                              ""       0
expect "no labels at all -> clears"                    ""                                         ""       0
expect "do-not-merge-exempt is not a hold"             "do-not-merge-exempt"                      ""       0
expect "DO-NOT-MERGE (uppercase) still blocks"         "DO-NOT-MERGE"                             ""       1

# --- fail-closed on the label read -----------------------------------------
expect "unreadable label list -> fails CLOSED"         "FAIL"                                     ""       1

# ---------------------------------------------------------------------------
# THE #1148 REGRESSION: a human-approved added by a NON-allowlisted actor
# must NOT clear needs-human-review. Under the pre-fix script (presence-only)
# this case would have gone green (exit 0); it must now fail closed (exit 1).
# Non-vacuousness is asserted immediately after by flipping ONLY the actor to
# an allowlisted one and watching it go green with everything else unchanged.
# ---------------------------------------------------------------------------
expect "human-approved by a NON-allowlisted actor does NOT clear needs-human-review (the #1148 shape)" \
       "$(printf 'needs-human-review\nhuman-approved')" "eve-not-on-the-allowlist" 1
expect "same case, actor flipped to allowlisted -> clears (proves the check above is non-vacuous)" \
       "$(printf 'needs-human-review\nhuman-approved')" "eve-not-on-the-allowlist" 0 "Sara3,eve-not-on-the-allowlist"

# --- adder-verification edge cases ------------------------------------------
expect "human-approved with NO matching labeled event -> unverifiable, fails CLOSED" \
       "$(printf 'needs-human-review\nhuman-approved')" "" 1
expect "human-approved added by a bot login -> unverifiable, fails CLOSED" \
       "$(printf 'needs-human-review\nhuman-approved')" "savvy-gate-bot[bot]" 1
expect "unreadable issue-events -> unverifiable, fails CLOSED" \
       "$(printf 'needs-human-review\nhuman-approved')" "FAIL" 1
expect "allowlist match is case-insensitive" \
       "$(printf 'needs-human-review\nhuman-approved')" "sara3" 0
expect "most recent labeled event wins: re-added by an allowlisted actor after a non-allowlisted one -> clears" \
       "$(printf 'needs-human-review\nhuman-approved')" "$(printf 'eve-not-on-the-allowlist\nSara3')" 0
expect "most recent labeled event wins: re-added by a non-allowlisted actor after an allowlisted one -> fails CLOSED" \
       "$(printf 'needs-human-review\nhuman-approved')" "$(printf 'Sara3\neve-not-on-the-allowlist')" 1
expect "human-approved present but no hold label at all -> clears regardless of adder (nothing was held)" \
       "human-approved" "eve-not-on-the-allowlist" 0

# ---------------------------------------------------------------------------
# CI-surface floor, evaluated HERE so it can't be outrun by gate.yml's `review`
# job (which computes the same match but can queue for minutes on the
# self-hosted pool — see savvy-frontend#349, [wo:human-review-floor-can-be-
# outrun-auto-merge-merged-a-ci-surface-pr-before-the-ga]).
# ---------------------------------------------------------------------------
expect "CI-surface file + no hold labels + no human-approved -> blocks" \
       "" "" 1 "Sara3" ".github/workflows/deploy.yml"
expect_contains "CI-surface block names CI-surface paths in its error" \
       "" "" "Sara3" ".github/workflows/deploy.yml" "CI-surface paths"

expect "CI-surface file + verified human-approved -> clears (override still works)" \
       "human-approved" "Sara3" 0 "Sara3" ".github/workflows/deploy.yml"

expect "CI-surface file + do-not-merge, no human-approved -> still blocks (precedence unchanged)" \
       "do-not-merge" "" 1 "Sara3" ".github/workflows/deploy.yml"
expect_contains "do-not-merge + CI-surface file shows the absolute-hold message, not the CI-surface one" \
       "do-not-merge" "" "Sara3" ".github/workflows/deploy.yml" "absolute hold"

expect "non-CI-surface file list, no labels -> clears (regression guard)" \
       "" "" 0 "Sara3" "src/index.ts"

expect "unreadable PR file list -> fails CLOSED" \
       "" "" 1 "Sara3" "FAIL"

# ---------------------------------------------------------------------------
# SHA-BINDING of the human-approved release (2026-10-02 review fix): an
# allowlisted human approves SHA A, then a push creates SHA B. merge-guard
# re-runs on `synchronize`; the old verified label event must NOT carry over.
#   approved_at (arg 7) vs the earliest workflow-run time of the live head (arg 8)
# ---------------------------------------------------------------------------
NHR="$(printf 'needs-human-review\nhuman-approved')"
expect "approve-then-push: label older than the live head's first run -> approval is STALE, hold applies" \
       "$NHR" "Sara3" 1 "Sara3" "README.md" "2026-10-02T10:00:00Z" "2026-10-02T11:00:00Z"
expect_contains "approve-then-push names the stale approval" \
       "$NHR" "Sara3" "Sara3" "README.md" "STALE" "2026-10-02T10:00:00Z" "2026-10-02T11:00:00Z"
expect "approve-then-push of a CI-surface edit (no hold label) -> the floor blocks it (was: exit 0 before the floor)" \
       "human-approved" "Sara3" 1 "Sara3" ".github/workflows/gate.yml" "2026-10-02T10:00:00Z" "2026-10-02T11:00:00Z"
expect "label added AFTER the head's first run (reviewed this commit) -> still clears (non-vacuous twin)" \
       "$NHR" "Sara3" 0 "Sara3" "README.md" "2026-10-02T11:00:01Z" "2026-10-02T11:00:00Z"
expect "same-second tie -> not current (fail-closed)" \
       "$NHR" "Sara3" 1 "Sara3" "README.md" "2026-10-02T11:00:00Z" "2026-10-02T11:00:00Z"
expect "unreadable workflow-run list -> approval not current (fail-closed)" \
       "$NHR" "Sara3" 1 "Sara3" "README.md" "2026-10-02T12:00:00Z" "FAIL"
expect "unreadable label time -> approval not current (fail-closed)" \
       "$NHR" "Sara3" 1 "Sara3" "README.md" "FAIL" "2026-10-02T11:00:00Z"
expect "CI-surface edit + current verified approval -> clears (override path unchanged)" \
       "human-approved" "Sara3" 0 "Sara3" ".github/workflows/gate.yml" "2026-10-02T12:00:00Z" "2026-10-02T11:00:00Z"

# --- the CI-surface definition now includes CODEOWNERS + dependabot.yml (and .claude/scripts/) ---
expect ".github/CODEOWNERS -> blocks (CI-surface)"      "" "" 1 "Sara3" ".github/CODEOWNERS"
expect ".github/dependabot.yml -> blocks (CI-surface)"  "" "" 1 "Sara3" ".github/dependabot.yml"
expect ".claude/scripts/x.js -> blocks (CI-surface)"    "" "" 1 "Sara3" ".claude/scripts/x.js"
expect "a file merely named like dependabot.yml elsewhere -> clears" "" "" 0 "Sara3" "docs/.github/dependabot.yml.md"

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS test(s) FAILED"
  exit 1
fi
echo "ALL TESTS PASSED"

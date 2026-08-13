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
# labels. Without this, a botched extraction would make every case below
# "pass" by running an empty script that exits 0.
if ! grep -q 'labels' "$GUARD_SH"; then
  echo "FAIL: extracted script never mentions labels — extraction is wrong"
  exit 1
fi

# run_guard <newline-separated-labels | FAIL> -> echoes the guard's exit code
run_guard() {
  local labels="$1"
  local bindir="$TMPROOT/bin"
  rm -rf "$bindir"; mkdir -p "$bindir"

  if [ "$labels" = "FAIL" ]; then
    printf '%s\n' '#!/bin/bash' 'echo "HTTP 502 Bad Gateway" >&2' 'exit 1' > "$bindir/gh"
  else
    {
      printf '%s\n' '#!/bin/bash'
      printf '%s\n' "cat <<'STUBLABELS'"
      printf '%s\n' "$labels"
      printf '%s\n' 'STUBLABELS'
    } > "$bindir/gh"
  fi
  chmod +x "$bindir/gh"

  PATH="$bindir:$PATH" \
  GITHUB_REPOSITORY="withSavvy/savvy_landing" \
  PR_NUMBER="1" \
  bash "$GUARD_SH" >/dev/null 2>&1
  echo $?
}

expect() {
  local desc="$1" labels="$2" want="$3"
  local got; got="$(run_guard "$labels")"
  if [ "$got" = "$want" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (wanted exit $want, got $got)"
    FAILS=$((FAILS + 1))
  fi
}

# --- absolute holds: block, and are NOT overridable ------------------------
expect "do-not-merge -> blocks"                        "do-not-merge"                             1
expect "hold -> blocks (the #728 near-miss)"           "hold"                                     1
expect "do-not-merge + human-approved -> still blocks" "$(printf 'do-not-merge\nhuman-approved')" 1
expect "hold + human-approved -> still blocks"         "$(printf 'hold\nhuman-approved')"         1

# --- advisory holds: block, but human-approved overrides -------------------
expect "needs-human-review -> blocks"                  "needs-human-review"                       1
expect "reviewing -> blocks"                           "reviewing"                                1
expect "human-approved overrides needs-human-review"   "$(printf 'needs-human-review\nhuman-approved')" 0
expect "human-approved overrides reviewing"            "$(printf 'reviewing\nhuman-approved')"    0

# --- clean / matching precision -------------------------------------------
expect "clean labels -> clears"                        "enhancement"                              0
expect "no labels at all -> clears"                    ""                                         0
expect "do-not-merge-exempt is not a hold"             "do-not-merge-exempt"                      0
expect "DO-NOT-MERGE (uppercase) still blocks"         "DO-NOT-MERGE"                             1

# --- fail-closed ----------------------------------------------------------
expect "unreadable label list -> fails CLOSED"         "FAIL"                                     1

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS test(s) FAILED"
  exit 1
fi
echo "ALL TESTS PASSED"

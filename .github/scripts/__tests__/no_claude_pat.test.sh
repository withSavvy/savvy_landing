#!/bin/bash
# Ratchet: no workflow may resolve the personal CLAUDE_PAT secret, and the
# savvy-gate-bot App token mint in gate.yml must fail the job (fail closed).
#
# CLAUDE_PAT is a Sara3 personal token. As a `||` fallback it let a mint failure
# silently hand a release-authorised identity (Sara3 is on TIER_B_RELEASE_ACTORS)
# to the reviewer/fixer steps. Static grep/awk only: no network, no YAML parser.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF_DIR="$HERE/../../workflows"
GATE_YML="$WF_DIR/gate.yml"
FAILS=0

if [ ! -f "$GATE_YML" ]; then
  echo "FAIL: gate.yml not found at $GATE_YML"
  exit 1
fi

# (1) No live (non-comment) reference to secrets.CLAUDE_PAT in any workflow.
live_refs="$(cd "$WF_DIR" && grep -HnE 'secrets\.CLAUDE_PAT' ./*.yml | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
if [ -n "$live_refs" ]; then
  echo "FAIL: live secrets.CLAUDE_PAT reference(s) in workflows:"
  echo "$live_refs"
  FAILS=$((FAILS + 1))
else
  echo "PASS: no live secrets.CLAUDE_PAT in any workflow"
fi

# (2) Every create-github-app-token step in gate.yml has no continue-on-error.
# A step runs from its `- ` list marker (at the indent of the first step under
# `steps:`) to the next marker at that indent. Comment lines are ignored.
mint_report="$(awk '
  function flush() {
    if (blk ~ /uses:[ \t]*actions\/create-github-app-token/) {
      mints++
      if (blk ~ /(^|\n)[ \t]*continue-on-error:/) bad++
    }
    blk = ""
  }
  /^[ \t]*#/ { next }
  /^[ \t]*steps:[ \t]*$/ { flush(); stepInd = -1; next }
  /^[ \t]*- / {
    match($0, /^[ \t]*/)
    if (stepInd < 0) stepInd = RLENGTH
    if (RLENGTH == stepInd) flush()
  }
  { blk = blk $0 "\n" }
  END { flush(); printf "%d %d\n", mints + 0, bad + 0 }
' "$GATE_YML")"
read -r mints bad <<<"$mint_report"
if [ "$mints" -lt 1 ]; then
  echo "FAIL: no create-github-app-token step found in gate.yml (test would be vacuous)"
  FAILS=$((FAILS + 1))
elif [ "$bad" -gt 0 ]; then
  echo "FAIL: $bad of $mints create-github-app-token step(s) in gate.yml carry continue-on-error"
  FAILS=$((FAILS + 1))
else
  echo "PASS: all $mints create-github-app-token step(s) in gate.yml fail closed (no continue-on-error)"
fi

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS test(s) FAILED"
  exit 1
fi
echo "ALL TESTS PASSED"

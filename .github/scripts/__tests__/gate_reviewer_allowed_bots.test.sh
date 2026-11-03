#!/bin/bash
# Drift guard: every claude-code-action step in gate.yml must set a non-empty
# allowed_bots.
#
# WHY THIS EXISTS
#
# claude-code-action refuses to run when the workflow's actor is a bot and the
# step's allowed_bots input is empty (the default). A PR that savvy-gate-bot
# opens or updates fires its pull_request run with actor savvy-gate-bot[bot],
# and a re-run keeps that actor. Until 2026-11-03 none of this repo's four
# reviewer steps set allowed_bots, the same configuration that makes them abort
# in savvy-email-worker and savvy-workspace with:
#
#   Workflow initiated by non-human actor: savvy-gate-bot (type: Bot). Add bot
#   to allowed_bots list or use '*' to allow all bots.
#
# (savvy-email-worker review job 117295318786, 2026-10-17; savvy-workspace
# opus-gate job 125577709985, 2026-11-02.) The reviewer steps in savvy-backend,
# savvy-frontend and savvy-mcp-server already set allowed_bots: "*".
#
# Run with: bash .github/scripts/__tests__/gate_reviewer_allowed_bots.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATE_YML="${GATE_YML:-$REPO_ROOT/.github/workflows/gate.yml}"
FAILS=0

assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILS=$((FAILS + 1)); fi
}

if [ ! -f "$GATE_YML" ]; then
  assert "gate.yml exists" 1
  echo "$FAILS test(s) FAILED"
  exit 1
fi

# One line per claude-code-action step: "<line> <id> <allowed_bots value or NONE>".
# A step runs from its `- uses: anthropics/claude-code-action@` line to the next
# line that starts a new step or job at the same or a shallower indent.
steps=$(awk '
  function flush() { if (start) { print start, (id == "" ? "(no-id)" : id), (ab == "" ? "NONE" : ab) } start = 0 }
  {
    match($0, /^ */); ind = RLENGTH
    if (start && ind <= step_ind && $0 ~ /^ *(- |[A-Za-z_-]+:)/) flush()
    if ($0 ~ /^ *- uses: anthropics\/claude-code-action@/) {
      flush(); start = NR; step_ind = ind; id = ""; ab = ""; next
    }
    if (start && $0 ~ /^ *id: /) { sub(/^ *id: */, ""); id = $0 }
    if (start && $0 ~ /^ *allowed_bots:/) {
      v = $0; sub(/^ *allowed_bots: */, "", v); sub(/ *#.*$/, "", v)
      if (v == "\"\"" || v == "'\'''\''" || v == "") v = "EMPTY"
      ab = v
    }
  }
  END { flush() }
' "$GATE_YML")

count=$(printf '%s\n' "$steps" | grep -c . || true)
assert "gate.yml has at least one claude-code-action step (found $count)" \
  "$([ "$count" -ge 1 ] && echo 0 || echo 1)"

while read -r line id ab; do
  [ -z "${line:-}" ] && continue
  assert "claude-code-action step '$id' (gate.yml:$line) sets a non-empty allowed_bots (got $ab)" \
    "$([ "$ab" != "NONE" ] && [ "$ab" != "EMPTY" ] && echo 0 || echo 1)"
done <<< "$steps"

assert "found all 4 reviewer steps (claude_review, claude_review_only, opus_review, opus_review_only)" \
  "$(for s in claude_review claude_review_only opus_review opus_review_only; do printf '%s\n' "$steps" | grep -q " $s " || exit 1; done; echo 0)"

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS test(s) FAILED"
  exit 1
fi
echo "All allowed_bots checks passed"

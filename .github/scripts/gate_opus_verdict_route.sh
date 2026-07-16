#!/usr/bin/env bash
# gate_opus_verdict_route.sh — terminal routing for gate.yml's "Enforce Opus
# verdict (binding terminal gate)" step, extracted so the workflow and the
# committed test (.github/scripts/__tests__/gate_opus_verdict_route.test.sh)
# exercise the exact same code (mirrors opus_decide.sh / select_binding.sh /
# gate_infra_escalate.sh / auto_arm_merge.sh — same pattern, same directory).
#
# Bug this fixes [wo:fix-gate-opus-gate-fail-arm-must-add-needs-human-review-
# reject-verdicts-silently]: opus-gate is intentionally NOT a required check
# (infra flakiness must never brick merges on its own), so a FAIL verdict does
# not block merge by itself — the needs-human-review label is what actually
# keeps a genuinely rejected PR out of auto-merge. Before this fix, the FAIL
# arm exited 1 WITHOUT adding that label, while both sibling arms (the
# OpenAI-FAIL backstop immediately above this case statement, and the
# no-verdict `*` arm below) already did. A real Opus REQUEST_CHANGES was
# therefore silently mergeable — the mechanism behind the 07-14 "REJECT
# shipped anyway" incident (savvy-workspace#1459, item 1).
#
# Usage: gate_opus_verdict_route.sh <VERDICT> <PR_NUMBER> <REPO>
#   VERDICT: PASS | FAIL | anything else (treated as "no verdict", fail-closed)
# Env: GH_TOKEN (or GITHUB_TOKEN) must be set for the gh calls — inherited from
#      the calling step's `env:` block, same as gate_infra_escalate.sh.
set -uo pipefail

VERDICT="${1:-}"
PR_NUMBER="${2:-}"
REPO="${3:-${GITHUB_REPOSITORY:-}}"

label_needs_human_review() {
  # Best-effort (|| true): a labeling hiccup must never mask the real verdict
  # — the exit code below is what actually blocks the workflow.
  gh pr edit "$PR_NUMBER" --add-label needs-human-review --repo "$REPO" || true
}

case "$VERDICT" in
  PASS)
    echo "Opus APPROVED — gate green."
    exit 0
    ;;
  FAIL)
    label_needs_human_review
    echo "::error::opus-gate: Opus REQUESTED CHANGES — blocking."
    exit 1
    ;;
  *)
    label_needs_human_review
    echo "::error::opus-gate: no verdict emitted — fail-closed."
    exit 1
    ;;
esac

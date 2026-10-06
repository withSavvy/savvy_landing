#!/usr/bin/env bash
# gate_infra_escalate.sh — uniform Type-C (infra/"couldn't run") escalation.
#
# A Type-C failure is NEITHER a passing check (we never proved the code is safe)
# NOR a code rejection (it is not the PR's fault). This script makes that explicit
# and human-visible, identically for every gate check:
#
#   1. Ensure the distinct `gate-infra-error` label exists (idempotent).
#   2. Label the PR `gate-infra-error` + `needs-human-review` on EVERY
#      occurrence (retried, with a REST read-back) so it leaves the auto-merge
#      path and enters the human queue, tagged as an infra failure (NOT "your
#      code was rejected").
#   3. Open OR update a single DEDUPED tracking issue per failing check class
#      (dedup key = a hidden marker in the issue body). Repeat occurrences add a
#      comment instead of spawning a new issue — so a flaky check yields ONE
#      issue with a running log, not a pile.
#   4. Post a sticky PR comment explaining "couldn't verify (infra) — not a code
#      rejection", so the PR author/ reviewer is never misled.
#
# All gh calls are best-effort (|| true) AFTER the routing decision is made — the
# caller has already decided to BLOCK (exit non-zero). This script only annotates;
# it must never itself flip a block into a pass.
#
# ── LABEL ON EVERY OCCURRENCE, WITH READ-BACK (2026-10-02, savvy-backend#1595 /
# tracking #1239 — ported to savvy_landing) ───────────────────────────────────
# savvy-backend reversed its "label only on the FIRST crash per PR+check" rule
# after #1595: a crashed-review PR lost its only backstop label and was
# bot-merged with no Opus verdict. savvy_landing never had the first-occurrence
# gate (the label was always re-applied), but the write was a bare `|| true`
# that was never read back, so one dropped call left an unreviewed PR with no
# backstop and no signal. The write now goes through gh_retry.sh and is read
# back over REST; a missing label is a loud ::error:: (this script still exits 0
# — it only annotates and must never itself flip a block into a pass).
# The release path no longer depends on label REMOVAL either: a crashed
# reviewer concludes opus-gate FAILURE and the required `opus-verdict-recorded`
# status reads failure; the ways out are a re-run of the failed jobs once the
# cause clears, or an allowlisted human adding `human-approved` (SHA-bound
# override, see verify_human_approved.sh). REMOVING LABELS NEVER RELEASES.
#
# Usage:
#   gate_infra_escalate.sh --pr <num> --check <name> --detail "<one-line cause>" \
#       [--run-url <actions-run-url>] [--repo <owner/repo>]
#
# Env: GH_TOKEN (or GITHUB_TOKEN) must be set for the gh calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PR=""; CHECK=""; DETAIL=""; RUN_URL=""; REPO="${GITHUB_REPOSITORY:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)      PR="$2"; shift 2 ;;
    --check)   CHECK="$2"; shift 2 ;;
    --detail)  DETAIL="$2"; shift 2 ;;
    --run-url) RUN_URL="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    *) echo "gate_infra_escalate: unknown arg '$1'" >&2; shift ;;
  esac
done

if [ -z "$CHECK" ]; then
  echo "::error::gate_infra_escalate: --check is required" >&2
  exit 0   # annotation helper — never block on our own arg error
fi

# gh wrapper that appends --repo only when REPO is known (owner/repo has no spaces,
# so this is safe; avoids empty-array expansion under `set -u` on older bash).
ghx() { if [ -n "$REPO" ]; then gh "$@" --repo "$REPO"; else gh "$@"; fi; }

# Derive the run URL if not supplied (so the issue/comment links to the failing run).
if [ -z "$RUN_URL" ] && [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  RUN_URL="${GITHUB_SERVER_URL}/${REPO}/actions/runs/${GITHUB_RUN_ID}"
fi
TS="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 'unknown-time')"

echo "::warning::gate-infra-error [$CHECK]: ${DETAIL:-infra error} — routed to human as 'couldn't verify' (NOT a code rejection)."

# 1. Ensure label exists (idempotent; create may fail if it already exists).
ghx label create gate-infra-error \
  --color B60205 \
  --description "Gate could not RUN a check (infra/environment error) — couldn't verify, not a code rejection" \
  >/dev/null 2>&1 || true

# 2. Label the PR (both: distinct infra tag + the human-queue tag) on EVERY
# occurrence. The write goes through gh_retry.sh (a transient gh failure must not
# silently drop the one backstop label), then is read back over REST — a write
# that reported success is not proof the label landed. gh_retry.sh runs as its own
# process, so it cannot see the `ghx` shell function above; call `gh` directly
# with an explicit --repo, mirroring gate.yml's own ROUTE_HUMAN arm.
if [ -n "$PR" ]; then
  if ! bash "${SCRIPT_DIR}/gh_retry.sh" --retries 2 --sleep 2 -- \
       gh issue edit "$PR" --add-label gate-infra-error --add-label needs-human-review --repo "$REPO"; then
    echo "::error::gate-infra-error: could not apply gate-infra-error/needs-human-review to PR #$PR after retries — the backstop label write failed."
  fi
  LABELS_NOW="$(bash "${SCRIPT_DIR}/gh_retry.sh" --retries 2 --sleep 2 -- \
    gh api "repos/${REPO}/issues/${PR}/labels" --jq '.[].name' || true)"
  if ! printf '%s\n' "$LABELS_NOW" | grep -qx needs-human-review; then
    echo "::error::gate-infra-error: needs-human-review is NOT present on PR #$PR after a reported-success label write — the backstop is missing and needs manual attention."
  fi
fi

# 3. Deduped tracking issue (one per check class). Dedup by a hidden body marker,
# matched with gh's built-in jq (no fragile inline Python in a command sub).
ISSUE_MARKER="<!-- gate-infra:${CHECK} -->"
EXISTING_ID="$(ghx issue list --state open --label gate-infra-error --limit 100 \
  --json number,body \
  --jq "map(select(.body | contains(\"$ISSUE_MARKER\"))) | .[0].number // empty" \
  2>/dev/null || true)"

OCCURRENCE="- ${TS} — PR #${PR:-?}${RUN_URL:+ — [run](${RUN_URL})}: ${DETAIL:-infra error}"

if [ -n "$EXISTING_ID" ]; then
  ghx issue comment "$EXISTING_ID" \
    --body "Recurred (gate could not run \`${CHECK}\`):
${OCCURRENCE}" >/dev/null 2>&1 || true
  echo "gate-infra-error: appended occurrence to tracking issue #${EXISTING_ID}"
else
  BODY="$(printf '%s\n\n%s\n\n%s\n\n%s\n' \
    "${ISSUE_MARKER}" \
    "**The savvy gate could not RUN the \`${CHECK}\` check** (Type-C / infra error). This is an environment/setup failure, **not** a code rejection — the affected PR(s) were routed to human review as \"couldn't verify\", never auto-passed and never chased by the auto-fixer." \
    "This is a **deduped** tracking issue — each recurrence appends a comment below instead of opening a new issue. Close it once the underlying infra cause (runner, registry, tool install, OOM, timeout, external API) is fixed." \
    "### Occurrences
${OCCURRENCE}")"
  ghx issue create \
    --title "[gate-infra] ${CHECK} — gate could not run (infra error)" \
    --label gate-infra-error \
    --body "$BODY" >/dev/null 2>&1 || true
  echo "gate-infra-error: opened tracking issue for check '${CHECK}'"
fi

# 4. Sticky PR comment (one per check class; updated in place).
if [ -n "$PR" ]; then
  CMARKER="<!-- gate-infra-comment:${CHECK} -->"
  BODY_FILE="$(mktemp 2>/dev/null || echo /tmp/gate_infra_comment.md)"
  {
    echo "$CMARKER"
    echo "### 🛠️ Gate infra error — could not verify (Type-C)"
    echo ""
    printf 'The **%s** check could not run to a trustworthy conclusion: `%s`\n' "$CHECK" "${DETAIL:-infra error}"
    echo ""
    echo "This is an **infrastructure/environment failure, not a code rejection.** Per the gate's Type-C contract this PR was:"
    echo "- **not auto-passed** (we never proved the code is safe), and"
    echo "- **not chased by the auto-fixer** (there is nothing in the code to fix), and"
    echo "- **routed to a human** with the \`gate-infra-error\` label + a deduped tracking issue."
    echo ""
    echo "**Removing labels does not release this PR** — the required \`opus-verdict-recorded\` status reads failure until the gate actually completes. Re-run the failed jobs once the infra cause is resolved, or have an allowlisted human review the diff and add \`human-approved\` (a SHA-bound override). ${RUN_URL:+[Failing run](${RUN_URL})}"
    echo ""
    echo "_— savvy gate · Type-C escalation_"
  } > "$BODY_FILE"

  CID="$(gh api "repos/${REPO}/issues/${PR}/comments" --paginate \
    --jq ".[]|select(.body|contains(\"$CMARKER\"))|.id" 2>/dev/null | head -1)"
  if [ -n "$CID" ]; then
    gh api -X PATCH "repos/${REPO}/issues/comments/${CID}" \
      -f body="$(cat "$BODY_FILE")" >/dev/null 2>&1 || true
  else
    ghx pr comment "$PR" --body-file "$BODY_FILE" >/dev/null 2>&1 || true
  fi
fi

exit 0

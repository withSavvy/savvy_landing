#!/bin/bash
# Drift guard for the review-only FALLBACK in gate.yml.
# [wo:opus-gate-reviewer-fails-its-own-permission-check-on-the-shared-app-installation]
#
# The fix passes (claude_review, opus_review) run claude-code-action on the
# shared savvy-gate-bot App installation token. When that installation's
# hourly REST quota is spent, the action dies at setup (GET /users/{actor}
# 403s) and writes no execution file. The review-only steps run on
# GITHUB_TOKEN, a separate quota, so they are the fallback that still gets the
# PR a real review.
#
# What it pins:
#   1. Each review-only step runs when its fixer RAN but wrote no exec file,
#      not only when loop_guard says review_only.
#   2. The review-only steps stay on GITHUB_TOKEN (the fallback is pointless
#      on the exhausted App token).
#   3. The fixers stay on the App token: only an App-authored push re-triggers
#      the gate, a GITHUB_TOKEN push does not.
#   4. The one-shot label is still stamped only when the fixer wrote an exec
#      file, so a setup crash never burns the fix pass.
#   5. The verdict readers fall through to the review-only exec file.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE_YML:-$TEST_DIR/../../workflows/gate.yml}"
FAILS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

# Print the step block that owns `id: <id>`: from its `      - ` opener to the
# line before the next step opener at the same indent.
step_block() {
  awk -v want="$1" '
    /^      - / { if (found) exit; buf = $0 "\n"; next }
    { buf = buf $0 "\n" }
    $0 ~ "^        id: " want "$" { found = 1 }
    END { if (found) printf "%s", buf }
  ' "$GATE"
}

# Same, keyed on the step name.
named_block() {
  awk -v want="$1" '
    /^      - / { if (found) exit; buf = $0 "\n"; started = index($0, want) > 0; if (started) found = 1; next }
    { buf = buf $0 "\n" }
    END { if (found) printf "%s", buf }
  ' "$GATE"
}

field() { grep -m1 -E "^        $2:" <<<"$1" | sed -E "s/^        $2: *//"; }

[ -f "$GATE" ] || { echo "FAIL: gate.yml not found at $GATE"; exit 1; }

for pair in "claude_review:claude_review_only" "opus_review:opus_review_only"; do
  fixer="${pair%%:*}"; ronly="${pair##*:}"
  fb=$(step_block "$fixer"); rb=$(step_block "$ronly")
  [ -n "$fb" ] || { fail "step id $fixer not found"; continue; }
  [ -n "$rb" ] || { fail "step id $ronly not found"; continue; }

  rif=$(field "$rb" if)
  if grep -qF "steps.$fixer.outputs.execution_file == ''" <<<"$rif" \
     && grep -qF "steps.$fixer.outcome != 'skipped'" <<<"$rif" \
     && grep -qF "steps.loop_guard.outputs.review_only == 'true' ||" <<<"$rif"; then
    pass "$ronly runs when review_only=true OR $fixer ran without an exec file"
  else
    fail "$ronly if: lacks the no-exec-file fallback on $fixer: $rif"
  fi

  if [ "$(field "$rb" '  github_token')" = '${{ secrets.GITHUB_TOKEN }}' ]; then
    pass "$ronly stays on secrets.GITHUB_TOKEN"
  else
    fail "$ronly github_token is '$(field "$rb" '  github_token')', expected secrets.GITHUB_TOKEN"
  fi

  if grep -qF 'steps.app_token.outputs.token' <<<"$(field "$fb" '  github_token')"; then
    pass "$fixer stays on the App token (its push must re-trigger the gate)"
  else
    fail "$fixer github_token is '$(field "$fb" '  github_token')', expected steps.app_token.outputs.token"
  fi
done

for pair in "Mark Sonnet fix used:claude_review" "Mark Opus fix used:opus_review"; do
  name="${pair%%:*}"; fixer="${pair##*:}"
  mif=$(field "$(named_block "$name")" if)
  if grep -qF "steps.$fixer.outputs.execution_file != ''" <<<"$mif"; then
    pass "'$name' only stamps the one-shot label when $fixer wrote an exec file"
  else
    fail "'$name' if: no longer requires an exec file from $fixer: $mif"
  fi
done

if grep -qE "REVIEW_EXEC_FILE: .*steps\.claude_review\.outputs\.execution_file \|\| steps\.claude_review_only\.outputs\.execution_file" "$GATE"; then
  pass "Sonnet verdict readers fall through to claude_review_only's exec file"
else
  fail "no Sonnet REVIEW_EXEC_FILE chain falls through to claude_review_only"
fi

if grep -qF 'EXEC_FILE="${{ steps.opus_review_only.outputs.execution_file }}"' "$GATE"; then
  pass "Opus enforce_verdict falls through to opus_review_only's exec file"
else
  fail "enforce_verdict no longer reads opus_review_only's exec file"
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "All review-only fallback checks passed."; exit 0; fi
echo "$FAILS check(s) failed."; exit 1

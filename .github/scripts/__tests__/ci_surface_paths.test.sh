#!/bin/bash
# Tests for ci_surface_paths.sh + the DRIFT guard between its CI_SURFACE_REGEX and
# merge-guard.yml's inline copy. [2026-10-02 review fix, savvy-backend#1595 / #1239]
#
# Before this, gate.yml's floors matched `^[.]github/(workflows|scripts)/` and
# merge-guard.yml matched that plus `^[.]claude/scripts/`; neither covered
# .github/CODEOWNERS or .github/dependabot.yml. One definition, three consumers
# (gate.yml floors + post_opus_verdict_recorded.sh source the script; merge-guard
# has no checkout so it carries the literal and THIS test keeps it identical).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$TEST_DIR/../ci_surface_paths.sh"
GUARD="$TEST_DIR/../../workflows/merge-guard.yml"
GATE="$TEST_DIR/../../workflows/gate.yml"
POST="$TEST_DIR/../post_opus_verdict_recorded.sh"
FAILS=0

assert() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILS=$((FAILS + 1)); fi
}

[ -f "$SRC" ] || { echo "Error: $SRC not found"; exit 1; }
# shellcheck source=../ci_surface_paths.sh
source "$SRC"
[ -n "${CI_SURFACE_REGEX:-}" ] && c=0 || c=1
assert "the script defines CI_SURFACE_REGEX" "$c"

hit()  { printf '%s\n' "$1" | grep -Eq "$CI_SURFACE_REGEX"; }
echo "--- behaviour ---"
for f in .github/workflows/gate.yml .github/scripts/x.sh .claude/scripts/y.js .github/CODEOWNERS .github/dependabot.yml; do
  hit "$f" && c=0 || c=1; assert "'$f' is CI-surface" "$c"
done
for f in README.md src/index.ts docs/.github/dependabot.yml .github/dependabot.yml.bak .github/CODEOWNERS.md .github/ISSUE_TEMPLATE/bug.md .claude/work-orders/x.md wrangler.jsonc; do
  hit "$f" && c=1 || c=0; assert "'$f' is NOT CI-surface" "$c"
done
hit "$(printf 'README.md\n.github/workflows/ci.yml')" && c=0 || c=1
assert "a multi-file list with one CI-surface path matches" "$c"

echo "--- DRIFT: merge-guard.yml inline literal == ci_surface_paths.sh ---"
guard_lit="$(grep -F "grep -Eq '" "$GUARD" | grep 'github/(workflows|scripts)' | sed -n "s/.*grep -Eq '\(.*\)'; then.*/\1/p" | head -n1)"
[ -n "$guard_lit" ] && c=0 || c=1
assert "found the CI-surface literal in merge-guard.yml (extraction non-vacuous)" "$c"
[ "$guard_lit" = "$CI_SURFACE_REGEX" ] && c=0 || c=1
assert "merge-guard's literal is byte-identical to CI_SURFACE_REGEX (edit BOTH). guard='$guard_lit' src='$CI_SURFACE_REGEX'" "$c"

echo "--- consumers use the shared definition ---"
[ "$(grep -c 'ci_surface_paths.sh' "$GATE")" -ge 2 ] && ! grep -Eq "grep -Eq '\^\[\.\]github/\(workflows\|scripts\)/'" "$GATE" && c=0 || c=1
assert "gate.yml sources ci_surface_paths.sh in both floors and keeps no private regex" "$c"
grep -q 'source "\$SCRIPT_DIR/ci_surface_paths.sh"' "$POST" && c=0 || c=1
assert "post_opus_verdict_recorded.sh sources ci_surface_paths.sh" "$c"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"

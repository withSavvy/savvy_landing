#!/bin/bash
# Behavioural test for auto-arm-merge.yml's arm-or-hold logic.
#
# This repo carries the logic INLINE in the workflow rather than in an
# extracted auto_arm_merge.sh (as savvy-backend / savvy-frontend /
# savvy-email-worker / savvy-mcp-server do), so this test extracts the real
# `run:` block out of the YAML and executes it. There is one copy of the logic
# and this test runs it — a test that re-implements its subject can only detect
# itself changing.
#
# The scenarios below are the ones the sibling repos' suites cover, plus the
# two defects that were specific to this repo's inline copy: labels read from
# the frozen $GITHUB_EVENT_PATH payload, and the escaped `card\[-_\]benefits`
# regex that matched a literal string instead of a filename.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
WF="$REPO_ROOT/.github/workflows/auto-arm-merge.yml"
FAILS=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

if [ ! -f "$WF" ]; then
  echo "FAIL: auto-arm-merge.yml not found at $WF"
  exit 1
fi

# Extract the single `run: |` block and dedent. No YAML parser needed (none is
# guaranteed on the runner).
ARM_SH="$TMPROOT/arm.sh"
awk '
  /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ && !seen {
    seen = 1; match($0, /^[[:space:]]*/); key_indent = RLENGTH; next
  }
  seen == 1 {
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    match($0, /^[[:space:]]*/)
    if (RLENGTH <= key_indent) { seen = 2; next }
    if (body_indent == 0) { body_indent = RLENGTH }
    print substr($0, body_indent + 1)
  }
' "$WF" > "$ARM_SH"

if [ ! -s "$ARM_SH" ] || ! bash -n "$ARM_SH"; then
  echo "FAIL: could not extract a valid run: block from auto-arm-merge.yml"
  exit 1
fi
# Guard the extraction itself: without this, a botched extract would make every
# scenario below "pass" by running an empty script that exits 0.
if ! grep -q 'gh pr merge' "$ARM_SH"; then
  echo "FAIL: extracted script never calls 'gh pr merge' — extraction is wrong"
  exit 1
fi

CALLS="$TMPROOT/calls.log"

# write_gh_stub <labels.seq path> <files> [fail_mode]
#   labels.seq: one LINE per successive `--json labels` read; the word NONE
#               means "no labels". Lines may hold several labels, comma-sep.
#   fail_mode:  labels | files | addlabel | merge  (that call fails hard)
write_gh_stub() {
  local seq="$1" files="$2" fail="${3:-}"
  local bin="$TMPROOT/bin"
  rm -rf "$bin"; mkdir -p "$bin"
  cp "$seq" "$TMPROOT/labels.seq"
  printf '%s\n' "$files" > "$TMPROOT/files.txt"
  printf '0\n' > "$TMPROOT/readcount"

  cat > "$bin/gh" <<STUB
#!/bin/bash
echo "\$*" >> "$CALLS"
case "\$*" in
  *"--json labels"*)
    [ "$fail" = "labels" ] && { echo "HTTP 502" >&2; exit 1; }
    n=\$(cat "$TMPROOT/readcount"); n=\$((n+1)); echo "\$n" > "$TMPROOT/readcount"
    line=\$(sed -n "\${n}p" "$TMPROOT/labels.seq")
    [ -z "\$line" ] && line=\$(tail -n1 "$TMPROOT/labels.seq")
    [ "\$line" = "NONE" ] && exit 0
    printf '%s\n' "\$line" | tr ',' '\n'
    ;;
  *"--json files"*)
    [ "$fail" = "files" ] && { echo "HTTP 502" >&2; exit 1; }
    cat "$TMPROOT/files.txt"
    ;;
  *"--add-label"*)
    [ "$fail" = "addlabel" ] && { echo "HTTP 502" >&2; exit 1; }
    ;;
  *"--auto --squash"*)
    [ "$fail" = "merge" ] && { echo "not mergeable" >&2; exit 1; }
    ;;
  *"--disable-auto"*) ;;
  *) ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"
}

run_arm() {
  : > "$CALLS"
  (
    cd "$REPO_ROOT" && \
    PATH="$TMPROOT/bin:$PATH" PR_NUMBER=123 GITHUB_REPOSITORY="withSavvy/savvy_landing" \
      GITHUB_TOKEN=x bash "$ARM_SH" > "$TMPROOT/out.log" 2>&1
  )
  echo $?
}

called()     { grep -q -- "$1" "$CALLS"; }
armed()      { grep -q -- "--auto --squash" "$CALLS"; }
disarmed()   { grep -q -- "--disable-auto" "$CALLS"; }
labelled()   { grep -q -- "--add-label" "$CALLS"; }

check() {
  local desc="$1" ok="$2"
  if [ "$ok" = "0" ]; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAILS=$((FAILS+1)); fi
}

seq_file() { printf '%s\n' "$@" > "$TMPROOT/seq"; echo "$TMPROOT/seq"; }

# --- 1. hold label present at open -> never arms ---------------------------
write_gh_stub "$(seq_file 'do-not-merge')" "README.md"
rc=$(run_arm)
if ! armed && disarmed && [ "$rc" = "0" ]; then check "hold label at open -> disarms, never arms" 0
else check "hold label at open -> disarms, never arms (rc=$rc)" 1; fi

# --- 2. `hold` specifically (parity with merge-guard.yml) ------------------
write_gh_stub "$(seq_file 'hold')" "README.md"
rc=$(run_arm)
if ! armed && disarmed; then check "'hold' label -> disarms, never arms (merge-guard parity)" 0
else check "'hold' label -> disarms, never arms (rc=$rc)" 1; fi

# --- 3. THE #575 RACE: label lands between first read and the re-check -----
write_gh_stub "$(seq_file 'NONE' 'do-not-merge')" "README.md"
rc=$(run_arm)
if ! armed && disarmed && [ "$rc" = "0" ]; then check "label added mid-run -> caught by re-check, never arms" 0
else check "label added mid-run -> caught by re-check, never arms (rc=$rc)" 1; fi

# --- 4. clean PR -> arms ---------------------------------------------------
write_gh_stub "$(seq_file 'NONE' 'NONE')" "README.md"
rc=$(run_arm)
if armed && [ "$rc" = "0" ]; then check "clean PR -> arms auto-merge" 0
else check "clean PR -> arms auto-merge (rc=$rc)" 1; fi

# --- 5. label read fails -> fail CLOSED ------------------------------------
write_gh_stub "$(seq_file 'NONE')" "README.md" labels
rc=$(run_arm)
if ! armed && [ "$rc" = "1" ]; then check "unreadable labels -> fails closed, never arms (rc=1)" 0
else check "unreadable labels -> fails closed, never arms (rc=$rc)" 1; fi

# --- 6. FILES fetch fails -> fail CLOSED (brick check must not be skipped) --
write_gh_stub "$(seq_file 'NONE')" "README.md" files
rc=$(run_arm)
if ! armed && [ "$rc" = "1" ]; then check "unreadable file list -> fails closed, never arms (rc=1)" 0
else check "unreadable file list -> fails closed, never arms (rc=$rc)" 1; fi

# --- 7. brick-risk path -> labels do-not-merge, never arms -----------------
write_gh_stub "$(seq_file 'NONE' 'NONE')" ".github/workflows/ci.yml"
rc=$(run_arm)
if ! armed && labelled && [ "$rc" = "0" ]; then check "workflow-touching PR -> do-not-merge applied, never arms" 0
else check "workflow-touching PR -> do-not-merge applied, never arms (rc=$rc)" 1; fi

# --- 8. brick-risk label write fails -> loud, never silently green ---------
write_gh_stub "$(seq_file 'NONE' 'NONE')" ".github/workflows/ci.yml" addlabel
rc=$(run_arm)
if ! armed && [ "$rc" = "1" ]; then check "do-not-merge write fails -> exits 1, not a silent green" 0
else check "do-not-merge write fails -> exits 1, not a silent green (rc=$rc)" 1; fi

# --- 9. card_benefits: the un-escaping fix ---------------------------------
# The inline copy previously wrote `card\[-_\]benefits` inside [[ =~ ]], which
# matches the LITERAL string "card[-_]benefits" and therefore never matched a
# real filename. savvy-workspace has a dedicated test for this same defect.
write_gh_stub "$(seq_file 'NONE' 'NONE')" "src/data/card_benefits.ts"
rc=$(run_arm)
if ! armed && labelled; then check "card_benefits.ts -> brick risk detected (unescaped regex)" 0
else check "card_benefits.ts -> brick risk detected (unescaped regex) (rc=$rc)" 1; fi

write_gh_stub "$(seq_file 'NONE' 'NONE')" "src/data/card-benefits.ts"
rc=$(run_arm)
if ! armed && labelled; then check "card-benefits.ts -> brick risk detected (hyphen form)" 0
else check "card-benefits.ts -> brick risk detected (hyphen form) (rc=$rc)" 1; fi

# --- 10. merge call fails -> loud ------------------------------------------
write_gh_stub "$(seq_file 'NONE' 'NONE')" "README.md" merge
rc=$(run_arm)
if [ "$rc" = "1" ]; then check "failed arm -> exits 1, no silent success" 0
else check "failed arm -> exits 1, no silent success (rc=$rc)" 1; fi

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS test(s) FAILED"
  exit 1
fi
echo "ALL TESTS PASSED"

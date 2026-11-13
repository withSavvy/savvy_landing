#!/bin/bash
# Pins that every claude-code-action reviewer step in gate.yml runs without
# repository-supplied Claude Code configuration: a strip step runs earlier in
# the same job, and claude_args restrict the setting sources and MCP config.
# Also exercises gate_strip_claude_config.sh in a temp git repo.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
GATE="$REPO_ROOT/.github/workflows/gate.yml"
CI="$REPO_ROOT/.github/workflows/ci.yml"
STRIP="$REPO_ROOT/.github/scripts/gate_strip_claude_config.sh"
FAILS=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

# Line-scan a workflow file (stdlib only). Prints one violation per line;
# empty output means every assertion (a)-(d), (f) holds.
check_gate() {
  python3 - "$1" <<'PY'
import re, sys

EXPECTED = {"claude_review", "claude_review_only", "opus_review", "opus_review_only"}
lines = open(sys.argv[1]).read().split("\n")
out = []

# Split into jobs (2-space keys under `jobs:`) and steps (6-space `- `).
jobs, job, step, in_jobs = {}, None, None, False
for ln in lines:
    if re.match(r"^jobs:\s*$", ln):
        in_jobs = True
        continue
    if not in_jobs:
        continue
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", ln)
    if m:
        job = m.group(1)
        jobs[job] = []
        step = None
        continue
    if job is None:
        continue
    if re.match(r"^      - ", ln):
        step = []
        jobs[job].append(step)
    if step is not None:
        step.append(ln)

found = {}
for jname, steps in jobs.items():
    stripped = False
    for st in steps:
        text = "\n".join(st)
        if "gate_strip_claude_config.sh" in text and re.search(r"^\s*(- )?run:", text, re.M):
            stripped = True
        if "anthropics/claude-code-action@" not in text:
            continue
        m = re.search(r"^\s+id:\s*(\S+)", text, re.M)
        sid = m.group(1) if m else "<no-id>"
        found[sid] = True
        if not stripped:
            out.append(f"(a) {sid}: no earlier strip step in job {jname}")
        am = re.search(r"claude_args:\s*\|\n((?:\s{12,}.*\n?)+)", text + "\n")
        args = am.group(1) if am else ""
        if not re.search(r"--setting-sources\s+local(\s|$)", args):
            out.append(f"(b) {sid}: missing --setting-sources local")
        if "--strict-mcp-config" not in args:
            out.append(f"(b) {sid}: missing --strict-mcp-config")
        if "--restricted" in args:
            tm = re.search(r"(?<![\w-])--tools\s+(\"[^\"]*\"|'[^']*'|\S+)", args)
            if not tm or not re.search(r"(?<![\w])Bash(\(|,|$|\s|\"|')", tm.group(1)):
                out.append(f"(d) {sid}: --restricted without --tools naming Bash")
        if not re.search(r"--allowedTools(\s|=)", args):
            out.append(f"(f) {sid}: missing --allowedTools")

for sid in EXPECTED:
    if sid not in found:
        out.append(f"(a) expected reviewer step {sid} not found")
for sid in found:
    if sid not in EXPECTED:
        out.append(f"(a) unexpected claude-code-action step {sid}")

env_val = None
for ln in lines:
    em = re.match(r"^\s*GATE_REVIEWER_ALLOWED_TOOLS:\s*\"([^\"]*)\"\s*$", ln)
    if em:
        env_val = em.group(1)
if env_val is None:
    out.append("(f) GATE_REVIEWER_ALLOWED_TOOLS env entry not found")
else:
    for need in ("Bash(git diff:*)", "Bash(gh pr diff:*)"):
        if need not in env_val:
            out.append(f"(f) GATE_REVIEWER_ALLOWED_TOOLS missing {need}")

for i, ln in enumerate(lines, 1):
    for m in re.finditer(r"--setting-sources(?:\s+(\S+))?", ln):
        val = (m.group(1) or "").strip("\"'")
        if val != "local":
            out.append(f"(c) line {i}: --setting-sources value {val!r} is not 'local'")

print("\n".join(out))
PY
}

echo "== gate.yml assertions =="
viol="$(check_gate "$GATE")"
if [ -z "$viol" ]; then pass "gate.yml (a)-(d), (f)"; else
  while IFS= read -r v; do fail "$v"; done <<<"$viol"
fi

echo "== ci.yml runs this test (e) =="
if grep -Eq 'gate_reviewer_config_isolation\.test\.sh|__tests__/\*\.test\.sh' "$CI"; then
  pass "ci.yml runs the isolation test"
else
  fail "(e) ci.yml does not run gate_reviewer_config_isolation.test.sh"
fi

echo "== mutation checks (each must be detected) =="
mutate() { # name mode
  local name="$1" mode="$2" out="$SANDBOX/mut.yml"
  python3 - "$GATE" "$out" "$mode" <<'PY'
import re, sys
src, dst, mode = sys.argv[1:4]
t = open(src).read()
if mode == "drop-strict":
    t = t.replace("--strict-mcp-config", "", 1)
elif mode == "drop-strip":
    t = re.sub(r"bash \.github/scripts/gate_strip_claude_config\.sh", "true", t, count=1)
elif mode == "empty-sources":
    t = t.replace("--setting-sources local", '--setting-sources ""', 1)
elif mode == "user-sources":
    t = t.replace("--setting-sources local", "--setting-sources user", 1)
elif mode == "restrict-review-only":
    i = t.index("id: claude_review_only")
    j = t.index("--strict-mcp-config", i) + len("--strict-mcp-config")
    t = t[:j] + " --restricted" + t[j:]
elif mode == "drop-diff-pattern":
    t = re.sub(r'(GATE_REVIEWER_ALLOWED_TOOLS: "[^"\n]*?)Bash\(gh pr diff:\*\),', r"\1", t, count=1)
if t == open(src).read():
    sys.exit("mutation mode %s did not change the file" % mode)
open(dst, "w").write(t)
PY
  if [ -z "$(check_gate "$out")" ]; then fail "mutation '$name' not detected"; else pass "mutation '$name' detected"; fi
}
mutate "drop --strict-mcp-config" drop-strict
mutate "drop a strip step" drop-strip
mutate "empty --setting-sources" empty-sources
mutate "--setting-sources user" user-sources
mutate "--restricted without --tools on a review-only step" restrict-review-only
mutate "drop gh pr diff from allowed tools" drop-diff-pattern

echo "== strip script behaviour =="
if [ ! -x "$STRIP" ]; then
  fail "gate_strip_claude_config.sh missing or not executable"
else
  R="$SANDBOX/repo"
  mkdir -p "$R/sub/deep" "$R/.claude/agents" "$R/.claude/scripts"
  (
    cd "$R" || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    : > .mcp.json; : > sub/CLAUDE.md; : > sub/deep/CLAUDE.local.md; : > CLAUDE.md
    : > .claude/settings.json; : > .claude/settings.local.json
    : > .claude/agents/x.md; : > .claude/scripts/a.js; : > .claude/review-kits.md
    : > keep.txt
    git add -A && git commit -q -m init
  )
  (cd "$R" && bash "$STRIP"); rc=$?
  [ "$rc" -eq 0 ] && pass "strip exits 0" || fail "strip exit $rc"
  left="$(cd "$R" && find . -path ./.git -prune -o -type f -print | sort | tr '\n' ' ')"
  [ "$left" = "./.claude/review-kits.md ./keep.txt " ] \
    && pass "only review-kits.md (and unrelated files) remain" || fail "unexpected leftovers: $left"
  (cd "$R" && git commit -a -q -m probe >/dev/null 2>&1)
  nlost="$(cd "$R" && git ls-tree -r --name-only HEAD | wc -l | tr -d ' ')"
  [ "$nlost" -eq 10 ] && pass "git commit -a stages no deletion" || fail "commit -a dropped tracked files (HEAD has $nlost, want 10)"
  (cd "$R" && bash "$STRIP") && pass "second run exits 0" || fail "second run failed"
  E="$SANDBOX/empty"; mkdir -p "$E"
  (cd "$E" && bash "$STRIP") && pass "empty non-git dir exits 0" || fail "empty dir run failed"
fi

echo "== strip script: symlinked .claude =="
if [ -x "$STRIP" ]; then
  L="$SANDBOX/linkrepo"
  mkdir -p "$L/claude-target"
  (
    cd "$L" || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    echo '{"a":1}' > claude-target/settings.json
    echo '{"b":2}' > claude-target/settings.local.json
    ln -s claude-target .claude
    : > keep.txt
    git add -A && git commit -q -m init
  )
  (cd "$L" && bash "$STRIP"); rc=$?
  [ "$rc" -eq 0 ] && pass "symlinked .claude: strip exits 0" || fail "symlinked .claude: strip exit $rc"
  if [ ! -e "$L/.claude" ] && [ ! -L "$L/.claude" ]; then
    pass "symlinked .claude removed in every form"
  else
    fail "symlinked .claude still present"
  fi
  if [ "$(cat "$L/claude-target/settings.json" 2>/dev/null)" = '{"a":1}' ] \
    && [ "$(cat "$L/claude-target/settings.local.json" 2>/dev/null)" = '{"b":2}' ]; then
    pass "link target left untouched"
  else
    fail "link target contents changed"
  fi
  (cd "$L" && git commit -a -q -m probe >/dev/null 2>&1)
  if (cd "$L" && git ls-tree -r --name-only HEAD | grep -qx '.claude'); then
    pass "git commit -a keeps the tracked link (no deletion)"
  else
    fail "git commit -a committed a deletion of .claude"
  fi
  (cd "$L" && bash "$STRIP") && pass "symlinked .claude: second run exits 0" || fail "symlinked .claude: second run failed"

  K="$SANDBOX/kitrepo"
  mkdir -p "$K/.claude"
  (
    cd "$K" || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    : > outside-kit.md
    ln -s ../outside-kit.md .claude/review-kits.md
    : > keep.txt
    git add -A && git commit -q -m init
  )
  (cd "$K" && bash "$STRIP")
  if [ ! -e "$K/.claude/review-kits.md" ] && [ ! -L "$K/.claude/review-kits.md" ]; then
    pass "symlinked review-kits.md removed"
  else
    fail "symlinked review-kits.md still present"
  fi
fi

echo "== strip script: fails closed when removal does nothing =="
if [ -x "$STRIP" ]; then
  F="$SANDBOX/failrepo"; STUB="$SANDBOX/stubbin"
  mkdir -p "$F" "$STUB"
  printf '#!/bin/sh\nexit 0\n' > "$STUB/rm"; chmod +x "$STUB/rm"
  : > "$F/.mcp.json"
  err="$(cd "$F" && PATH="$STUB:$PATH" bash "$STRIP" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] && pass "no-op rm: strip exits 1" || fail "no-op rm: strip exit $rc (want 1)"
  case "$err" in
    *.mcp.json*) pass "stderr names the leftover path" ;;
    *) fail "stderr does not name .mcp.json: $err" ;;
  esac
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASSED"; exit 0; fi
echo "$FAILS FAILED"; exit 1

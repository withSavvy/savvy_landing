#!/bin/bash
# Remove Claude Code configuration supplied by the PR checkout before a gate
# reviewer step runs: .mcp.json, every CLAUDE.md / CLAUDE.local.md, and
# everything directly under .claude/ except review-kits.md (which the reviewer
# prompts read). A symlinked .claude is removed as a link (never followed), and
# a symlinked .claude/review-kits.md is removed too. Run from the repo root.
# Idempotent; exits 0 when nothing exists. Tracked targets are marked
# skip-worktree first so a later `git commit -a` cannot commit the deletions.
# Fails closed: exits 1 (naming each path on stderr) if any config file is
# still present or resolvable after removal.
set -uo pipefail

# Link test comes before any -d test because -d follows links.
targets() {
  [ -e .mcp.json ] || [ -L .mcp.json ] && printf '%s\0' .mcp.json
  find . -path ./.git -prune -o \( -name CLAUDE.md -o -name CLAUDE.local.md \) -print0
  if [ -L .claude ]; then
    printf '%s\0' .claude
  elif [ -d .claude ]; then
    find .claude -mindepth 1 -maxdepth 1 ! \( -name review-kits.md ! -type l \) -print0
  fi
}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  targets | xargs -0 -r git ls-files -z -- 2>/dev/null \
    | xargs -0 -r git update-index --skip-worktree
fi

if [ -L .claude ]; then
  rm -f -- .claude
fi
targets | xargs -0 -r rm -rf --

leftover=0
report() {
  printf 'gate_strip_claude_config: still present: %s\n' "$1" >&2
  leftover=1
}
for p in .mcp.json .claude/settings.json .claude/settings.local.json; do
  if [ -e "$p" ] || [ -L "$p" ]; then report "$p"; fi
done
while IFS= read -r -d '' p; do
  report "$p"
done < <(find . -path ./.git -prune -o \( -name CLAUDE.md -o -name CLAUDE.local.md \) -print0)

[ "$leftover" -eq 0 ] || exit 1
exit 0

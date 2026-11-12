#!/bin/bash
# Remove Claude Code configuration supplied by the PR checkout before a gate
# reviewer step runs: .mcp.json, every CLAUDE.md / CLAUDE.local.md, and
# everything directly under .claude/ except review-kits.md (which the reviewer
# prompts read). Run from the repo root. Idempotent; exits 0 when nothing exists.
# Tracked targets are marked skip-worktree first so a later `git commit -a`
# cannot commit the deletions.
set -uo pipefail

targets() {
  [ -e .mcp.json ] || [ -L .mcp.json ] && printf '%s\0' .mcp.json
  find . -path ./.git -prune -o \( -name CLAUDE.md -o -name CLAUDE.local.md \) -print0
  if [ -d .claude ] || [ -L .claude ]; then
    find .claude -mindepth 1 -maxdepth 1 ! -name review-kits.md -print0
  fi
}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  targets | xargs -0 -r git ls-files -z -- 2>/dev/null \
    | xargs -0 -r git update-index --skip-worktree
fi

targets | xargs -0 -r rm -rf --
exit 0

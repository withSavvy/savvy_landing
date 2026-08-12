#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSETSIGNORE="$REPO_ROOT/.assetsignore"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

cp "$ASSETSIGNORE" "$SCRATCH/.gitignore"
git -C "$SCRATCH" init -q

fail=0

assert_hidden() {
  local path="$1"
  if git -C "$SCRATCH" check-ignore --no-index -q -- "$path"; then
    echo "OK    hidden:    $path"
  else
    echo "FAIL  published (must be hidden): $path"
    fail=1
  fi
}

assert_published() {
  local path="$1"
  if git -C "$SCRATCH" check-ignore --no-index -q -- "$path"; then
    echo "FAIL  hidden (must be published): $path"
    fail=1
  else
    echo "OK    published: $path"
  fi
}

assert_hidden "dashboard.html"
assert_hidden "docs/signup-architecture-proposal.md"
assert_hidden "docs"
assert_hidden "README.md"
assert_hidden "wrangler.jsonc"
assert_hidden ".github/workflows/deploy.yml"
assert_hidden "some-file-nobody-has-created-yet.html"
assert_hidden "nested/new/path-that-does-not-exist.json"

assert_published "index.html"
assert_published "privacy.html"
assert_published "robots.txt"
assert_published "sitemap.xml"

exit "$fail"

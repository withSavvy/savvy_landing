#!/usr/bin/env bash
# find_sticky_comment.sh — find a PR/issue comment ID whose body contains a
# marker string, without paginating the entire comment thread on every call.
#
# [wo:p0-the-gate-app-installation-token-is-rate-limit-exhausted-so-every-opus-gate-ru]
# The gate posts/updates one sticky comment per reviewer tier per PR run. The
# prior form (`gh api ... --paginate --jq '...'`) always walked every comment
# page to find the marker, even though the marker comment is near-always on
# page 1 (the gate created it, and PR comment threads rarely exceed 100
# entries). This checks page 1 first (per_page=100, one API call covering the
# common case) and only falls back to full pagination if the marker isn't
# there — e.g. a very old marker pushed past page 1 by other activity.
#
# Usage: find_sticky_comment.sh <repo> <pr_number> <marker>
# Prints: the comment ID on stdout (empty string if not found). Never fails
# closed — an API error yields "not found", matching prior behavior where the
# gate falls back to posting a new comment.
set -uo pipefail

REPO="${1:?find_sticky_comment: repo required}"
PR_NUMBER="${2:?find_sticky_comment: pr number required}"
MARKER="${3:?find_sticky_comment: marker required}"

CID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" \
  --jq ".[]|select(.body|contains(\"${MARKER}\"))|.id" 2>/dev/null | head -1)

if [ -z "$CID" ]; then
  CID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --paginate \
    --jq ".[]|select(.body|contains(\"${MARKER}\"))|.id" 2>/dev/null | head -1)
fi

printf '%s\n' "$CID"

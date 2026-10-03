#!/usr/bin/env bash
# gate_probe_installation.sh — is the gate App installation REST-rate-limited
# RIGHT NOW? Prints `key=value` diag lines for gate_check_ran.py.
#
# [2026-10-02, savvy-backend#1595 / tracking #1239] 32 of the 34 recorded
# NO_EXEC_FILE_INFRA crashes were GitHub 403 "API rate limit exceeded for
# installation ID 146412380" on the REST call claude-code-action makes before
# the review starts. The preflight `/rate_limit` read cannot classify them: it
# read 4,885-4,995 calls remaining moments before the 403 (a burst drain of
# ~5k calls in under 60s), so gate_check_ran.py's `remaining <= 5` rule never
# fired and every one landed in the anonymous NO_EXEC_FILE_INFRA arm.
#
# Only run when the reviewer wrote NO execution file (the caller checks), with
# the SAME App token the reviewer used, against the same REST bucket class.
# `GET /users/<actor>` is the call the action makes after #1536.
#
# Lines emitted (all single-line, none derived from PR-controlled text):
#   installation_probe_status=<http status | skipped | error>
#   installation_probe_remaining=<x-ratelimit-remaining or empty>
#   installation_probe_reset_epoch=<x-ratelimit-reset or empty>
#   installation_probe_resource=<x-ratelimit-resource (core|search|...) or empty>
#   installation_probe_message=<GitHub's own "message" field, <=200 chars>
#
# remaining + resource are what separate a hard bucket drain (remaining=0) from
# a REST throttle with budget left (remaining>0: a burst / secondary limit):
# gate_check_ran.py maps them to INSTALLATION_RATE_LIMIT_INFRA vs
# INSTALLATION_REST_THROTTLE_INFRA.
#
# Env: APP_TOKEN (the gate App token; empty -> status=skipped, because a
# GITHUB_TOKEN/PAT probe says nothing about the installation bucket),
# GITHUB_ACTOR. Exit 0 always: a diagnostic must not fail the job.
set -uo pipefail

ACTOR="${GITHUB_ACTOR:-}"
STATUS="skipped"; REMAINING=""; RESET=""; RESOURCE=""; MESSAGE=""

# A GitHub login is [A-Za-z0-9-] (plus a literal "[bot]" suffix for apps).
# Anything else is not interpolated into the API path.
if [ -n "${APP_TOKEN:-}" ] && printf '%s' "$ACTOR" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\[bot\])?$'; then
  OUT="$(GH_TOKEN="$APP_TOKEN" gh api -i "/users/${ACTOR}" 2>/dev/null || true)"
  OUT="$(printf '%s' "$OUT" | tr -d '\r')"
  FIRST="$(printf '%s\n' "$OUT" | head -n1)"
  if printf '%s' "$FIRST" | grep -Eq '^HTTP/[0-9.]+ [0-9]{3}'; then
    STATUS="$(printf '%s' "$FIRST" | awk '{print $2}')"
    REMAINING="$(printf '%s\n' "$OUT" | grep -i -m1 '^x-ratelimit-remaining:' | cut -d: -f2- | tr -d '[:space:]')"
    RESET="$(printf '%s\n' "$OUT" | grep -i -m1 '^x-ratelimit-reset:' | cut -d: -f2- | tr -d '[:space:]')"
    RESOURCE="$(printf '%s\n' "$OUT" | grep -i -m1 '^x-ratelimit-resource:' | cut -d: -f2- | tr -d '[:space:]')"
    MESSAGE="$(printf '%s\n' "$OUT" | grep -o -m1 '"message": *"[^"]*"' | head -n1 | sed 's/^"message": *"//; s/"$//' | cut -c1-200)"
  else
    STATUS="error"
  fi
fi

printf 'installation_probe_status=%s\n' "$STATUS"
printf 'installation_probe_remaining=%s\n' "$REMAINING"
printf 'installation_probe_reset_epoch=%s\n' "$RESET"
printf 'installation_probe_resource=%s\n' "$RESOURCE"
printf 'installation_probe_message=%s\n' "$MESSAGE"
exit 0

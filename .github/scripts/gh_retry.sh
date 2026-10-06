#!/usr/bin/env bash
# gh_retry.sh — retry a gh/network command N times before signalling infra failure.
#
# Type-C contract for gh/network plumbing calls (gh pr view / gh pr diff):
#   - A transient gh failure (API rate-limit, DNS hiccup, 5xx) is retried up to
#     --retries times with a fixed sleep.
#   - On persistent failure the caller is told via EXIT CODE 2 so it can call
#     gate_infra_escalate.sh and fail closed. Exit 2 is NEVER auto-passed.
#   - On success the command's stdout is echoed to stdout (and to --out-file if given);
#     exit 0.
#
# RATE-LIMIT 403 [2026-10-02, savvy-backend#1595 / tracking #1239]: when the failed
# call's output says GitHub rate-limited it (an HTTP 403/429 whose body mentions
# "rate limit" — "API rate limit exceeded for installation ID ...", or a
# secondary/abuse limit), a 2-5s retry only burns more of the same bucket (the
# savvy-gate-bot installation drain is a ~5k-call burst that clears over tens of
# seconds). Such a failure waits at least GH_RETRY_RATE_LIMIT_SLEEP (default 60s)
# plus 0..GH_RETRY_RATE_LIMIT_JITTER (default 15s) of random jitter, never less
# than --sleep. Every other failure keeps the fixed --sleep.
#
# NEVER use this for commands with Type-B semantics (real findings) — those must stay
# immediate, no-retry blocks. This is purely for infrastructure calls whose only
# failure mode is "the API didn't respond", not "the code contains a bad finding".
#
# Usage:  gh_retry.sh [--retries N] [--sleep S] [--out-file PATH] -- <gh args...>
# Exit:   0 = success;  2 = persistent infra failure (caller must infra-escalate)
set -uo pipefail

RETRIES=2
SLEEP=5
RATE_LIMIT_SLEEP="${GH_RETRY_RATE_LIMIT_SLEEP:-60}"
RATE_LIMIT_JITTER="${GH_RETRY_RATE_LIMIT_JITTER:-15}"
[[ "$RATE_LIMIT_SLEEP" =~ ^[0-9]+$ ]] || RATE_LIMIT_SLEEP=60
[[ "$RATE_LIMIT_JITTER" =~ ^[0-9]+$ ]] || RATE_LIMIT_JITTER=15

# True when the failed call's output is a GitHub rate-limit 403/429.
is_rate_limited() {
  printf '%s' "$1" | grep -Eqi '(403|429)' \
    && printf '%s' "$1" | grep -Eqi 'rate limit'
}
OUT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --retries)  RETRIES="$2"; shift 2 ;;
    --sleep)    SLEEP="$2";   shift 2 ;;
    --out-file) OUT_FILE="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "gh_retry: unknown arg '$1'" >&2; shift ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "::error::gh_retry: no command supplied (expected after --)" >&2
  exit 2
fi

attempt=0
while : ; do
  echo "  ▶ [gh_retry] attempt $((attempt + 1))/$((RETRIES + 1)): $*" >&2
  if OUTPUT=$("$@" 2>&1); then
    [ -n "$OUT_FILE" ] && printf '%s\n' "$OUTPUT" > "$OUT_FILE"
    printf '%s\n' "$OUTPUT"
    exit 0
  fi
  rc=$?
  echo "  ✗ [gh_retry] failed (rc=$rc)" >&2
  if [ "$attempt" -lt "$RETRIES" ]; then
    attempt=$((attempt + 1))
    WAIT="$SLEEP"
    if is_rate_limited "$OUTPUT"; then
      WAIT=$((RATE_LIMIT_SLEEP + RANDOM % (RATE_LIMIT_JITTER + 1)))
      [ "$WAIT" -lt "$SLEEP" ] && WAIT="$SLEEP"
      echo "  ⏳ [gh_retry] GitHub rate-limit 403/429 — waiting ${WAIT}s (not ${SLEEP}s) so the bucket can refill." >&2
    fi
    echo "  ⟳ [gh_retry] retrying in ${WAIT}s ($attempt/$RETRIES)..." >&2
    sleep "$WAIT"
  else
    echo "::error::[gh_retry] persistent gh failure after $((RETRIES + 1)) attempts — infra escalation required." >&2
    exit 2
  fi
done

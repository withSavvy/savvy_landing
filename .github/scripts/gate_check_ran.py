#!/usr/bin/env python3
"""Decide a claude-code-action review outcome. Prints ONE token:
PASS | ROUTE_HUMAN | FAIL_HARD | AUTH_FAIL | NO_EXEC_FILE_INFRA |
INSTALLATION_RATE_LIMIT_INFRA | INSTALLATION_REST_THROTTLE_INFRA.

Source of truth is the action's EXECUTION FILE (its `result` event / `is_error`),
NOT the `conclusion` output. claude-code-action@v1 does not reliably populate
`outputs.conclusion` (it renders empty even on a review that ran and succeeded),
so keying the gate on it fails closed on healthy reviews and jams the whole board.
The execution file is always written when the action actually runs, so it is the
authoritative signal for "did the review run, and did it error".

Decision tree (first match wins):
  A. PR edits .github/workflows/** OR the action self-skipped -> ROUTE_HUMAN.
     The action cannot push fixes to workflow files (the token lacks the
     `workflows` scope), so a "clean" review there only means "nothing it could
     apply" — a CI-surface change must never auto-pass; a human signs it off.
  B. No parseable result event -> the review never produced output (auth failure,
     crash, missing file). A file that is PRESENT but empty/corrupt/unparseable
     -> FAIL_HARD. Still catches the ~2s silent-swallow auth failure that #125
     guarded against.
     [2026-10-02, savvy-backend#1595 / tracking #1239 — ported to savvy_landing]
     A file that is ABSENT entirely means the action died BEFORE Claude ran (any
     Claude-phase error still writes the execution file), so no-file == a
     prepare/auth/install/network-phase death. If gate.yml's "Capture reviewer
     diagnostics" step recorded the action step's own outcome=failure
     (structural, never model text) this is infra, not a code rejection:
       * `installation_probe_status=403|429` + a message containing "rate limit
         exceeded for installation" (a live REST probe made with the same App
         token, only when the execution file is missing). 32 of the 34 #1239
         occurrences were this burst on the savvy-gate-bot installation; the
         action's own REST call dies with a 403 before the review starts. Split
         by the probe's x-ratelimit-remaining:
           remaining > 0 -> INSTALLATION_REST_THROTTLE_INFRA (the REST bucket
                            still has budget: a burst/secondary throttle, which
                            clears in about a minute)
           remaining = 0 -> INSTALLATION_RATE_LIMIT_INFRA (bucket drained until
                            x-ratelimit-reset)
           remaining unreadable -> INSTALLATION_RATE_LIMIT_INFRA (conservative).
       * any other crash -> NO_EXEC_FILE_INFRA.
     With no crash evidence (undeterminable cause, or no diag file passed) ->
     FAIL_HARD, fail closed. Never PASS on this arm. Every one of these is a
     non-pass for the binding verdict (gate_binding_verdict.sh): none of them can
     read as success.
  C. Result event present but is_error -> auth failure -> AUTH_FAIL (loud, actionable);
     max-turns routes to human (ran long but didn't finish); any other error -> FAIL_HARD.
  D. `conclusion` is populated AND explicitly not "success" -> defensive
     cross-check; treat as error (max-turns -> human, else FAIL_HARD).
  E. Result event present, not is_error, conclusion not contradicting -> PASS.
"""
import json
import os
import sys
from typing import Any, Optional

conclusion: str = sys.argv[1] if len(sys.argv) > 1 else ""
skipped: str = sys.argv[2] if len(sys.argv) > 2 else ""
exec_file: str = sys.argv[3] if len(sys.argv) > 3 else ""
edits_workflows: str = sys.argv[4] if len(sys.argv) > 4 else ""
diag_file: str = sys.argv[5] if len(sys.argv) > 5 else ""


def result_event(path: str) -> Optional[dict[str, Any]]:
    if not path:
        return None
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return None
    if not isinstance(data, list):
        return None
    return next((e for e in data if isinstance(e, dict) and e.get("type") == "result"), None)


def stopped_on_max_turns(res: dict[str, Any]) -> bool:
    """True when the result event itself says the run stopped at the turn limit.

    Scoped to the result event's own fields (`subtype` / `result` text) so it can
    never false-match on a 'max_turns' string quoted elsewhere in the transcript
    (prompt echoes, tool output, the PR diff Claude quotes back).
    """
    blob = f"{res.get('subtype', '')} {res.get('result', '')}".lower()
    return "max_turns" in blob


def is_auth_failure(path: str) -> bool:
    """True iff the action failed Anthropic auth (401). STRUCTURAL fields only —
    `error`/`error_status`/`api_error_status` are emitted by the SDK, never by the
    reviewer's free text, so a PR diff that merely quotes '401 Invalid bearer token'
    cannot spoof this (same injection-safety rule as gate_verdict.py)."""
    if not path:
        return False
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return False
    if not isinstance(data, list):
        return False
    for e in data:
        if not isinstance(e, dict):
            continue
        if e.get("error") == "authentication_failed":
            return True
        if e.get("error_status") == 401 or e.get("api_error_status") == 401:
            return True
    return False


def _diag_value(path: str, wanted: str) -> Optional[str]:
    """Value of the first whole-line `wanted=<value>` entry in the diagnostics
    file, or None when the file/key is absent or unreadable.

    STRUCTURAL, spoof-safe: every key is written by gate.yml's own capture step
    (steps.<id>.outcome values and gate_probe_installation.sh), never from the
    reviewer's free text or PR-controlled input."""
    if not path:
        return None
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except Exception:
        return None
    for line in lines:
        key, sep, value = line.partition("=")
        if sep and key.strip() == wanted:
            return value.strip()
    return None


def action_step_crashed(path: str) -> bool:
    """True iff the diagnostics file records that the claude-code-action step
    itself FAILED (`steps.<id>.outcome` == `failure`, the pre-continue-on-error
    result). Exact whole-line key=value only; absent/unreadable -> False."""
    return any(
        _diag_value(path, key) == "failure"
        for key in ("fix_pass_outcome", "review_only_pass_outcome")
    )


def installation_probe_rate_limited(path: str) -> bool:
    """True iff the live installation probe (a REST call made with the gate App
    token AFTER the reviewer crashed without an execution file) came back
    403/429 with GitHub's own "rate limit exceeded for installation" message.
    Missing/unreadable/other status -> False."""
    if _diag_value(path, "installation_probe_status") not in ("403", "429"):
        return False
    message = _diag_value(path, "installation_probe_message") or ""
    return "rate limit exceeded for installation" in message.lower()


def installation_probe_has_budget(path: str) -> bool:
    """True iff the probe's x-ratelimit-remaining parsed as an integer > 0, i.e.
    the installation's REST bucket is NOT drained and the 403 was a throttle.
    Empty/non-numeric/0 -> False (treated as a drained bucket)."""
    raw = _diag_value(path, "installation_probe_remaining") or ""
    return raw.isdigit() and int(raw) > 0


def decide() -> str:
    # A. Workflow-file edits (or an explicit action skip) always need a human.
    if skipped == "true" or edits_workflows == "true":
        return "ROUTE_HUMAN"

    res = result_event(exec_file)

    # B. No result event -> review never ran cleanly -> fail closed.
    if res is None:
        # B1. File present but empty/corrupt: not trustworthy crash evidence.
        if exec_file and os.path.isfile(exec_file):
            return "FAIL_HARD"
        # B2. File ABSENT: the action died before Claude ran. Structural crash
        #     evidence from the diag file names the class; otherwise undeterminable.
        if action_step_crashed(diag_file):
            if installation_probe_rate_limited(diag_file):
                if installation_probe_has_budget(diag_file):
                    return "INSTALLATION_REST_THROTTLE_INFRA"
                return "INSTALLATION_RATE_LIMIT_INFRA"
            return "NO_EXEC_FILE_INFRA"
        # B3. No crash evidence: cause undeterminable -> fail closed.
        return "FAIL_HARD"

    # C. Result event errored.
    if res.get("is_error"):
        if is_auth_failure(exec_file):
            return "AUTH_FAIL"
        return "ROUTE_HUMAN" if stopped_on_max_turns(res) else "FAIL_HARD"

    # D. Defensive cross-check on a populated, non-success conclusion.
    if conclusion and conclusion != "success":
        return "ROUTE_HUMAN" if stopped_on_max_turns(res) else "FAIL_HARD"

    # E. Ran clean.
    return "PASS"


print(decide())

#!/usr/bin/env python3
"""Decide a claude-code-action review outcome. Prints ONE token: PASS | ROUTE_HUMAN | FAIL_HARD | AUTH_FAIL.

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
     crash, missing file) -> FAIL_HARD. Still catches the ~2s silent-swallow auth
     failure that #125 guarded against.
  C. Result event present but is_error -> auth failure -> AUTH_FAIL (loud, actionable);
     max-turns routes to human (ran long but didn't finish); any other error -> FAIL_HARD.
  D. `conclusion` is populated AND explicitly not "success" -> defensive
     cross-check; treat as error (max-turns -> human, else FAIL_HARD).
  E. Result event present, not is_error, conclusion not contradicting -> PASS.
"""
import json
import sys
from typing import Any, Optional

conclusion: str = sys.argv[1] if len(sys.argv) > 1 else ""
skipped: str = sys.argv[2] if len(sys.argv) > 2 else ""
exec_file: str = sys.argv[3] if len(sys.argv) > 3 else ""
edits_workflows: str = sys.argv[4] if len(sys.argv) > 4 else ""


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


def decide() -> str:
    # A. Workflow-file edits (or an explicit action skip) always need a human.
    if skipped == "true" or edits_workflows == "true":
        return "ROUTE_HUMAN"

    res = result_event(exec_file)

    # B. No result event -> review never ran cleanly -> fail closed.
    if res is None:
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

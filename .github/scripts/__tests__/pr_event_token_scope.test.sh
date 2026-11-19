#!/bin/bash
# Guard: workflows started by a pull request event keep no long-lived admin
# credential and mint only narrowly scoped App tokens.
#
# WHY THIS EXISTS
#
# This repository is public, and a workflow started by a pull request runs its
# own file with repository secrets. For every workflow whose triggers include
# pull_request, pull_request_review or pull_request_target this test fails when:
#
#   (a) an actions/create-github-app-token step has no permission-* input, or
#       carries one outside checks / contents / issues / pull-requests;
#   (b) any step, job-level env or workflow-level env references the
#       CLAUDE_PAT or AUTOMATION_ADMIN_PAT secret;
#   (c) in gate.yml, an actions/checkout whose token is an App-token step output
#       does not set persist-credentials: false (jobs listed in
#       PERSIST_EXEMPT_JOBS are the documented exception, see below).
#
# Each rule is a Python function over a parsed workflow dict, exercised on the
# real tree plus one inline must-fail sample per rule and a must-pass sample so
# the checker cannot pass vacuously. Dispatch-only workflows are not checked.
#
# Run with: bash .github/scripts/__tests__/pr_event_token_scope.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT

python3 -I - <<'PY'
import glob
import json
import os
import re
import sys

import yaml

REPO_ROOT = os.environ["REPO_ROOT"]
PR_TRIGGERS = {"pull_request", "pull_request_review", "pull_request_target"}
ALLOWED_PERMISSIONS = {
    "permission-checks",
    "permission-contents",
    "permission-issues",
    "permission-pull-requests",
}
SECRET_RE = re.compile(r"secrets\.(CLAUDE_PAT|AUTOMATION_ADMIN_PAT)\b")
MINT_USES = "actions/create-github-app-token"
CHECKOUT_USES = "actions/checkout"
APP_TOKEN_REF_RE = re.compile(r"steps\.([A-Za-z0-9_-]+)\.outputs\.token")
# The reviewer/fixer jobs let claude-code-action run `git commit` / `git push`
# against the checkout (GATE_REVIEWER_ALLOWED_TOOLS), which needs the stored
# credential, so their checkouts keep it. Any other job must not.
PERSIST_EXEMPT_JOBS = {"review", "opus-gate"}

fails = 0


def assert_(desc, ok):
    global fails
    if ok:
        print("PASS: " + desc)
    else:
        print("FAIL: " + desc)
        fails += 1


def triggers(doc):
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return set(on)
    if isinstance(on, dict):
        return set(on)
    return set()


def is_pr_event(doc):
    return bool(triggers(doc) & PR_TRIGGERS)


def iter_jobs(doc):
    for job_id, job in (doc.get("jobs") or {}).items():
        if isinstance(job, dict):
            yield job_id, job


def iter_steps(doc):
    for job_id, job in iter_jobs(doc):
        for step in job.get("steps") or []:
            if isinstance(step, dict):
                yield job_id, step


def uses_of(step, prefix):
    return str(step.get("uses", "")).startswith(prefix)


def rule_a(doc):
    out = []
    for job_id, step in iter_steps(doc):
        if not uses_of(step, MINT_USES):
            continue
        keys = {k for k in (step.get("with") or {}) if str(k).startswith("permission-")}
        if not keys:
            out.append(f"{job_id}: app-token mint has no permission-* input")
        for extra in sorted(keys - ALLOWED_PERMISSIONS):
            out.append(f"{job_id}: app-token mint requests {extra}")
    return out


def rule_b(doc):
    out = []
    if SECRET_RE.search(json.dumps(doc.get("env") or {}, default=str)):
        out.append("workflow env references a forbidden secret")
    for job_id, job in iter_jobs(doc):
        if SECRET_RE.search(json.dumps(job.get("env") or {}, default=str)):
            out.append(f"{job_id}: job env references a forbidden secret")
    for job_id, step in iter_steps(doc):
        if SECRET_RE.search(json.dumps(step, default=str)):
            out.append(f"{job_id}: step references a forbidden secret")
    return out


def rule_c(doc, exempt_jobs=PERSIST_EXEMPT_JOBS):
    out = []
    for job_id, job in iter_jobs(doc):
        if job_id in exempt_jobs:
            continue
        steps = [s for s in job.get("steps") or [] if isinstance(s, dict)]
        mint_ids = {s.get("id") for s in steps if uses_of(s, MINT_USES) and s.get("id")}
        for step in steps:
            if not uses_of(step, CHECKOUT_USES):
                continue
            with_ = step.get("with") or {}
            ref = APP_TOKEN_REF_RE.search(str(with_.get("token", "")))
            if not ref or ref.group(1) not in mint_ids:
                continue
            if str(with_.get("persist-credentials", "")).lower() != "false":
                out.append(f"{job_id}: checkout with the App token lacks persist-credentials: false")
    return out


def check(doc, is_gate=False, exempt_jobs=PERSIST_EXEMPT_JOBS):
    out = rule_a(doc) + rule_b(doc)
    if is_gate:
        out += rule_c(doc, exempt_jobs)
    return out


def parse(text):
    return yaml.safe_load(text)


# --- inline samples ---------------------------------------------------------
# The secret name is assembled so this file never contains the literal reference.
BAD_SECRET = "${{ secrets." + "CLAUDE_PAT" + " }}"
HEAD = "on: pull_request\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n"
MINT_OK = (
    "      - id: app_token\n        uses: actions/create-github-app-token@v3\n        with:\n"
    "          app-id: x\n          permission-checks: write\n          permission-pull-requests: write\n"
)
SAMPLES = {
    "pass": HEAD + MINT_OK
    + "      - uses: actions/checkout@v7\n        with:\n"
    "          token: ${{ steps.app_token.outputs.token || secrets.GITHUB_TOKEN }}\n"
    "          persist-credentials: false\n",
    "a-no-permission": HEAD
    + "      - id: app_token\n        uses: actions/create-github-app-token@v3\n        with:\n          app-id: x\n",
    "a-administration": HEAD + MINT_OK + "          permission-administration: write\n",
    "b-forbidden-secret": HEAD + "      - run: echo hi\n        env:\n          GH_TOKEN: " + BAD_SECRET + "\n",
    "c-persisted": HEAD + MINT_OK
    + "      - uses: actions/checkout@v7\n        with:\n"
    "          token: ${{ steps.app_token.outputs.token }}\n",
    "dispatch-only": "on: workflow_dispatch\njobs:\n  j:\n    runs-on: x\n    steps:\n      - run: echo ${{ secrets.AUTOMATION_ADMIN_PAT }}\n",
}

assert_("must-pass sample reports no violation", check(parse(SAMPLES["pass"]), True) == [])
assert_("rule (a): mint without permission-* is reported", bool(rule_a(parse(SAMPLES["a-no-permission"]))))
assert_("rule (a): permission-administration is reported", bool(rule_a(parse(SAMPLES["a-administration"]))))
assert_("rule (b): forbidden secret is reported", bool(rule_b(parse(SAMPLES["b-forbidden-secret"]))))
assert_("rule (c): App-token checkout without persist-credentials is reported", bool(rule_c(parse(SAMPLES["c-persisted"]))))
assert_("rule (c): the exemption list does not hide other jobs", bool(rule_c(parse(SAMPLES["c-persisted"]), {"review"})))
assert_("rule (c): string 'false' is accepted",
        rule_c(parse(SAMPLES["pass"].replace("persist-credentials: false", "persist-credentials: 'false'"))) == [])
assert_("dispatch-only workflow is not a PR-event workflow", not is_pr_event(parse(SAMPLES["dispatch-only"])))
assert_("'on' as a list is parsed", triggers(parse("on: [push, pull_request_review]\njobs: {}\n")) == {"push", "pull_request_review"})

# --- real tree --------------------------------------------------------------
paths = sorted(
    glob.glob(os.path.join(REPO_ROOT, ".github/workflows/*.yml"))
    + glob.glob(os.path.join(REPO_ROOT, ".github/workflows/*.yaml"))
)
assert_("workflow files found", len(paths) > 0)
pr_with_mint = 0
for path in paths:
    name = os.path.basename(path)
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    if not isinstance(doc, dict) or not is_pr_event(doc):
        continue
    if any(uses_of(s, MINT_USES) for _, s in iter_steps(doc)):
        pr_with_mint += 1
    problems = check(doc, is_gate=(name == "gate.yml"))
    assert_(f"{name}: no token-scope violations" + ("" if not problems else " -> " + "; ".join(problems)), not problems)
assert_("at least one PR-event workflow with an App-token mint was checked", pr_with_mint >= 1)
rearm = os.path.join(REPO_ROOT, ".github/workflows/rearm-branch-protection.yml")
if os.path.exists(rearm):
    with open(rearm) as fh:
        assert_("rearm-branch-protection.yml (dispatch only) is not checked", not is_pr_event(yaml.safe_load(fh)))

if fails:
    print(f"{fails} test(s) FAILED")
    sys.exit(1)
print("ALL TESTS PASSED")
PY

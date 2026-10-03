#!/bin/bash
# Structural / convention test for the binding Opus verdict.
# [savvy-backend#1595 / tracking #1239, ported to savvy_landing]
#
# Incident: a PR was bot-merged at 22:29:20Z, four minutes BEFORE its opus-gate
# crashed (NO_EXEC_FILE_INFRA) and concluded `success` at 22:33:51Z. Two faults:
#   1. opus-gate / review are not the checks the merge waits on and start only
#      after the tier-0 jobs finish, so a merge armed early had nothing to wait for.
#   2. Every infra arm of the reviewer-enforcement steps `exit 0`s by design, so a
#      crash concluded the job SUCCESS and read as a clean verdict.
# The fix is structural and THIS FILE FREEZES ITS SHAPE (static, no network):
#   - opus-gate ENDS with `binding` + `conclude` (`if: always()`); review ENDS with
#     `conclude`. Anything appended after them would run after the verdict is decided.
#   - record-opus-verdict turns the verdict into the commit status
#     `opus-verdict-recorded`; `statuses: write` lives on exactly the recorder and
#     the human-override job, NEVER at workflow level.
#   - the recorder `if` is exactly `!cancelled()` (a bare always() makes a
#     superseded run immortal; any extra clause could skip it and leave the
#     required context missing).
#   - no job is DISPLAYED as `opus-verdict-recorded`, so a future required-check
#     flip cannot be satisfied by the recorder job's own check-run.
#   - gate.yml has no paths/paths-ignore filter.
#   - the opus floor exempts a failed review ONLY via needs.review.outputs.infra_token;
#     the Mark-fix-used steps require an execution file; docs-only no longer skips Opus.
#   - allowed_non_write_users is never passed without CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0
#     (it forces SCRUB=1, which needs bubblewrap: the #1239 NO_EXEC_FILE_INFRA crash).
#   - the override job lives in auto-arm-merge.yml, fires only on `labeled`
#     `human-approved` (never `unlabeled`: removing labels never releases), and
#     checks out the BASE BRANCH TIP (not the PR-open-time base.sha, which would
#     leave PRs opened before this merged with no recorder/override script).
#   - [review fix] CODEOWNERS covers /.github/ and /.claude/scripts/ (the only guard
#     a PR cannot edit; see gate.yml's KNOWN LIMIT), ci.yml's required `gate` job
#     RUNS these tests, merge-guard's human-approved release is SHA-bound, and
#     the dependabot success path reads the live file list.
#
# Needs python3 + PyYAML (preinstalled on GitHub-hosted runners; `pip install pyyaml`).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FAIL: python3 PyYAML is required (pip install pyyaml)"
  exit 1
fi

ROOT="$ROOT" python3 - <<'PY'
import os, re, stat, sys
import yaml

ROOT = os.environ["ROOT"]
WF = os.path.join(ROOT, ".github", "workflows")
SC = os.path.join(ROOT, ".github", "scripts")
fails = 0


def check(desc, cond):
    global fails
    if cond:
        print(f"PASS: {desc}")
    else:
        print(f"FAIL: {desc}")
        fails += 1


def load(name):
    with open(os.path.join(WF, name)) as f:
        text = f.read()
    return text, yaml.safe_load(text)


def norm_if(v):
    """Normalise an `if:` value: strip a ${{ }} wrapper and whitespace."""
    s = str(v).strip()
    m = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", s, re.S)
    return (m.group(1) if m else s).strip()


gate_text, gate = load("gate.yml")
arm_text, arm = load("auto-arm-merge.yml")
guard_text, guard = load("merge-guard.yml")
jobs = gate["jobs"]
opus = jobs["opus-gate"]
review = jobs["review"]
rec = jobs.get("record-opus-verdict", {})

print("--- opus-gate ends with binding + conclude ---")
osteps = opus["steps"]
check("opus-gate parses with steps", len(osteps) > 5)
check("last two steps are `binding` then `conclude`",
      [s.get("id") for s in osteps[-2:]] == ["binding", "conclude"])
check("both are `if: always()`", all(norm_if(s.get("if")) == "always()" for s in osteps[-2:]))
concl = osteps[-1].get("run", "")
check("conclude exits 1 unless the verdict is exactly PASS (no NOT_REQUIRED class in this repo)",
      'if [ "${BINDING_VERDICT:-}" = "PASS" ]' in concl and re.search(r"^\s*exit 1\s*$", concl, re.M) is not None
      and "NOT_REQUIRED" not in concl)
b = osteps[-2]
benv = b.get("env", {})
check("`binding` feeds gate_binding_verdict.sh from structural contexts only",
      benv == {
          "JOB_STATUS": "${{ job.status }}",
          "FLOOR_OUTCOME": "${{ steps.floor_check.conclusion }}",
          "RISK_TIER": "${{ steps.risk_tier.outputs.tier }}",
          "ENFORCE_TOKEN": "${{ steps.enforce_opus_ran.outputs.token }}",
          "ENFORCE_VERDICT_OUTCOME": "${{ steps.enforce_verdict.outcome }}",
      } and "gate_binding_verdict.sh" in b["run"] and "github.event" not in b["run"])
check("the job exposes the verdict as output `binding_verdict`",
      opus.get("outputs", {}).get("binding_verdict") == "${{ steps.binding.outputs.binding_verdict }}")
check("'Enforce Opus verdict' carries id enforce_verdict (the binding step reads its outcome)",
      any(s.get("id") == "enforce_verdict" and s.get("name", "").startswith("Enforce Opus verdict") for s in osteps))

print("--- review ends with conclude and exposes infra_token ---")
rsteps = review["steps"]
check("the LAST step is `conclude` with `if: always()`",
      rsteps[-1].get("id") == "conclude" and norm_if(rsteps[-1].get("if")) == "always()")
check("conclude runs gate_review_conclude.sh from structural contexts",
      "gate_review_conclude.sh" in rsteps[-1].get("run", "")
      and rsteps[-1].get("env", {}) == {
          "JOB_STATUS": "${{ job.status }}",
          "FLOOR_OUTCOME": "${{ steps.floor_check.conclusion }}",
          "ENFORCE_TOKEN": "${{ steps.enforce_review_ran.outputs.token }}",
      })
check("review exports infra_token from the conclude step",
      review.get("outputs", {}).get("infra_token") == "${{ steps.conclude.outputs.infra_token }}")
enf = [s for s in rsteps if s.get("id") == "enforce_review_ran"]
check("the review enforce step has an id and writes its token output",
      len(enf) == 1 and 'echo "token=$TOKEN" >> "$GITHUB_OUTPUT"' in enf[0]["run"])

print("--- the recorder job ---")
check("exists, needs only opus-gate", rec.get("needs") in (["opus-gate"], "opus-gate"))
check("its job-level `if` is exactly !cancelled()", norm_if(rec.get("if")) == "!cancelled()")
check("job-scoped permissions: statuses write + contents read + pull-requests read (dependabot file list), nothing else",
      rec.get("permissions") == {"contents": "read", "pull-requests": "read", "statuses": "write"})
check("display name is not the required context name", rec.get("name") == "record opus verdict")
check("runs on this repo's CI_RUNNER convention, never the CI_RUNNER_OVERFLOW chain",
      "vars.CI_RUNNER ||" in str(rec.get("runs-on")) and "OVERFLOW" not in str(rec.get("runs-on")))
rsteps2 = rec.get("steps", [])
check("checks out the BASE BRANCH TIP, never the frozen-at-open base.sha and never the PR head",
      any("actions/checkout" in s.get("uses", "") and s.get("with", {}).get("ref") == "${{ github.base_ref }}" for s in rsteps2)
      and "pull_request.base.sha" not in str(rsteps2) and "head" not in str([s.get("with", {}).get("ref") for s in rsteps2]))
post = [s for s in rsteps2 if "post_opus_verdict_recorded.sh" in s.get("run", "")]
check("posts through post_opus_verdict_recorded.sh with GITHUB_TOKEN (creator github-actions[bot])",
      len(post) == 1 and post[0].get("env", {}).get("GH_TOKEN") == "${{ secrets.GITHUB_TOKEN }}")
check("passes PR-derived values through env, never inline in the run: script",
      len(post) == 1 and "${{" not in post[0]["run"]
      and post[0]["env"].get("BINDING_VERDICT") == "${{ needs.opus-gate.outputs.binding_verdict }}"
      and post[0]["env"].get("PR_NUMBER") == "${{ github.event.pull_request.number }}")

print("--- statuses: write holders ---")
holders = []
wf_level = []
for fn in sorted(os.listdir(WF)):
    if not fn.endswith((".yml", ".yaml")):
        continue
    _, doc = load(fn)
    perms = doc.get("permissions")
    if isinstance(perms, dict) and perms.get("statuses") == "write":
        wf_level.append(fn)
    for jid, job in (doc.get("jobs") or {}).items():
        jp = job.get("permissions")
        if isinstance(jp, dict) and jp.get("statuses") == "write":
            holders.append(f"{fn}:{jid}")
check("no workflow grants statuses at workflow level", wf_level == [])
check("statuses: write is held by exactly the recorder and the override",
      sorted(holders) == ["auto-arm-merge.yml:record-human-opus-override", "gate.yml:record-opus-verdict"])
named = []
for fn in sorted(os.listdir(WF)):
    if not fn.endswith((".yml", ".yaml")):
        continue
    _, doc = load(fn)
    for jid, job in (doc.get("jobs") or {}).items():
        if jid == "opus-verdict-recorded" or job.get("name") == "opus-verdict-recorded":
            named.append(f"{fn}:{jid}")
check("no job is keyed or displayed `opus-verdict-recorded`", named == [])

print("--- nothing can skip the recorder ---")
on = gate.get(True, gate.get("on", {}))
check("gate.yml has no paths / paths-ignore filter",
      not any(k in (on.get("pull_request") or {}) for k in ("paths", "paths-ignore")))
check("gate.yml still triggers on pull_request", "pull_request" in on)

print("--- reviewer-crash plumbing ---")
floor = [s for s in osteps if s.get("id") == "floor_check"]
check("the opus floor exempts a failed review ONLY via needs.review.outputs.infra_token",
      len(floor) == 1
      and floor[0].get("env", {}).get("REVIEW_INFRA_TOKEN") == "${{ needs.review.outputs.infra_token }}"
      and re.search(r'REVIEW_RESULT" = "failure" \] && printf .%s. "\$\{REVIEW_INFRA_TOKEN:-\}" \| grep -Eq', floor[0]["run"]) is not None)
marks = [s for s in rsteps + osteps if s.get("name", "").startswith("Mark ") and "fix used" in s.get("name", "")]
check("both 'Mark ... fix used' steps exist", len(marks) == 2)
check("Mark fix used steps require the fixer to have written an execution file",
      all("execution_file != ''" in s.get("if", "") for s in marks))
rt = [s for s in osteps if s.get("id") == "risk_tier"]
check("docs-only no longer skips Opus: the risk tier never emits tier=docs",
      len(rt) == 1 and "tier=docs" not in rt[0]["run"] and 'echo "tier=high" >> "$GITHUB_OUTPUT"' in rt[0]["run"])
check("no step is conditional on a docs tier or an 'Auto-pass docs-only' skip",
      "tier == 'docs'" not in gate_text and "Auto-pass docs-only" not in gate_text)

def action_steps():
    for jid in ("review", "opus-gate"):
        for s in jobs[jid]["steps"]:
            if "anthropics/claude-code-action" in str(s.get("uses", "")):
                yield jid, s
bad = [f"{j}:{s.get('id')}" for j, s in action_steps()
       if "allowed_non_write_users" in (s.get("with") or {})
       and str((s.get("env") or {}).get("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "")) != "0"]
check("no claude-code-action step passes allowed_non_write_users without CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0", bad == [])
check("claude-code-action steps exist (guards a vacuous pass)", len(list(action_steps())) == 4)
for jid, stepid in (("review", "review_diag"), ("opus-gate", "opus_diag")):
    d = [s for s in jobs[jid]["steps"] if s.get("id") == stepid]
    check(f"{jid}: diagnostics step records outcomes + live installation probe with the App token",
          len(d) == 1 and "fix_pass_outcome" in d[0]["run"] and "gate_probe_installation.sh" in d[0]["run"]
          and d[0].get("env", {}).get("APP_TOKEN") == "${{ steps.app_token.outputs.token }}")
check("both gate_check_ran.py calls pass the diag file as the 5th argument",
      len(re.findall(r'gate_check_ran\.py \\\n\s+"" \\\n\s+"" \\\n\s+"\$\{(?:REVIEW|OPUS)_EXEC_FILE\}" \\\n\s+"\$EDITS_WF" \\\n\s+"\$\{(?:REVIEW|OPUS)_DIAG_FILE:-\}"', gate_text)) == 2)

print("--- auto-arm-merge.yml: record-human-opus-override ---")
ov = arm["jobs"].get("record-human-opus-override", {})
cond = str(ov.get("if", ""))
check("fires only on labeled human-approved from a same-repo PR",
      "github.event.pull_request.head.repo.full_name == github.repository" in cond
      and "github.event.action == 'labeled'" in cond and "github.event.label.name == 'human-approved'" in cond)
check("job-scoped permissions include statuses: write, no contents: write",
      ov.get("permissions", {}).get("statuses") == "write" and ov["permissions"].get("contents") == "read")
check("checks out the BASE BRANCH TIP (base.ref, never base.sha / the PR head), non-cancelling concurrency per PR and head sha",
      any(s.get("with", {}).get("ref") == "${{ github.event.pull_request.base.ref }}" for s in ov.get("steps", []))
      and not any("base.sha" in str(s.get("with", {})) or "head" in str(s.get("with", {}).get("ref", "")) for s in ov.get("steps", []))
      and ov.get("concurrency", {}).get("cancel-in-progress") is False
      and "pull_request.number" in ov["concurrency"]["group"] and "head.sha" in ov["concurrency"]["group"])
ost = [s for s in ov.get("steps", []) if "record_human_opus_override.sh" in s.get("run", "")]
check("runs record_human_opus_override.sh with PR values env-passed and GITHUB_TOKEN only",
      len(ost) == 1 and "${{" not in ost[0]["run"] and ost[0]["env"].get("GH_TOKEN") == "${{ secrets.GITHUB_TOKEN }}"
      and ost[0]["env"].get("EVENT_HEAD_SHA") == "${{ github.event.pull_request.head.sha }}")
types = (arm.get(True, arm.get("on", {})).get("pull_request_target") or {}).get("types")
check("the trigger did not widen: no `unlabeled`-driven release", types == ["opened", "ready_for_review", "labeled"])
check("runs on this repo's CI_RUNNER convention, never the CI_RUNNER_OVERFLOW chain",
      "vars.CI_RUNNER ||" in str(ov.get("runs-on")) and "OVERFLOW" not in str(ov.get("runs-on")))

print("--- merge-guard.yml: live CI-surface floor (a convenience block; NOT an anti-spoof control, see CODEOWNERS below) ---")
mg = guard["jobs"]["merge-guard"]
mrun = "\n".join(s.get("run", "") for s in mg["steps"])
check("merge-guard evaluates the CI-surface floor from the LIVE file list",
      "pulls/${PR_NUMBER}/files" in mrun
      and "^[.]github/(workflows|scripts)/|^[.]claude/scripts/|^[.]github/(CODEOWNERS|dependabot[.]yml)$" in mrun)
check("the CI-surface floor comes AFTER the verified human-approved release and the hold checks",
      mrun.index("verified_human_approved_adder") < mrun.index("pulls/${PR_NUMBER}/files")
      and mrun.index("reviewing|needs-human-review") < mrun.index("pulls/${PR_NUMBER}/files"))
check("merge-guard honours human-approved only through verified_human_approved_adder",
      "if verified_human_approved_adder; then" in mrun)
check("merge-guard's human-approved release is SHA-bound: the exit-0 sits inside human_approval_is_current_for_head",
      re.search(r"if verified_human_approved_adder; then\s+if human_approval_is_current_for_head; then\s+echo [^\n]*\n[^\n]*\n\s+exit 0", mrun) is not None
      and "actions/runs?head_sha=" in mrun)
check("merge-guard holds only the read scopes it needs (pull-requests + actions read), no write",
      mg.get("permissions") == {"pull-requests": "read", "actions": "read"})
check("merge-guard still has no checkout step (required label-only check on the hosted pool)",
      not any("actions/checkout" in s.get("uses", "") for s in mg["steps"]))
check("merge-guard stays on a GitHub-hosted runner literal", mg.get("runs-on") == "ubuntu-latest")

print("--- the only guard a PR cannot edit: CODEOWNERS + the tests actually run in CI ---")
with open(os.path.join(ROOT, ".github", "CODEOWNERS")) as f:
    owners = [l.split() for l in f if l.strip() and not l.lstrip().startswith("#")]
owned = {o[0]: o[1:] for o in owners}
check("CODEOWNERS owns /.github/ and /.claude/scripts/ with @Sara3 (covers workflows, scripts, CODEOWNERS, dependabot.yml)",
      owned.get("/.github/") == ["@Sara3"] and owned.get("/.claude/scripts/") == ["@Sara3"])
_, ci = load("ci.yml")
cisteps = ci["jobs"]["gate"]["steps"]
check("ci.yml's required `gate` job runs every .github/scripts/__tests__/*.test.sh and fails on any failure",
      any(".github/scripts/__tests__/*.test.sh" in s.get("run", "") and "rc=1" in s.get("run", "")
          and 'exit "$rc"' in s.get("run", "") for s in cisteps))
dep = [s for s in rsteps2 if "post_opus_verdict_recorded.sh" in s.get("run", "")]
check("the dependabot success path needs PR_NUMBER (live file list) — passed to the post script",
      len(dep) == 1 and "PR_NUMBER" in dep[0].get("env", {}))

print("--- scripts exist and are executable ---")
for name in ("gate_binding_verdict.sh", "gate_review_conclude.sh", "gate_probe_installation.sh",
             "post_opus_verdict_recorded.sh", "record_human_opus_override.sh", "verify_human_approved.sh",
             "gate_infra_escalate.sh", "gh_retry.sh", "ci_surface_paths.sh"):
    p = os.path.join(SC, name)
    check(f"{name} exists and is executable", os.path.isfile(p) and bool(os.stat(p).st_mode & stat.S_IXUSR))

if fails:
    print(f"{fails} test(s) FAILED")
    sys.exit(1)
print("ALL TESTS PASSED")
PY

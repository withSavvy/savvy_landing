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
#   - [review fix 2] the recorder + override check out the DEFAULT branch tip (not
#     base_ref) and post nothing unless the PR's base IS the default branch; both
#     run on a literal ubuntu-latest; ci.yml is read-only and starts python only
#     from an empty dir; the binding/conclude scripts are re-fetched after the
#     model steps and run under `env -i`; .claude/settings.json has no bare Bash.
#
# Needs python3 + PyYAML (preinstalled on GitHub-hosted runners; `pip install pyyaml`).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

# python3 -c / python3 - put the CWD (the PR checkout root) FIRST on sys.path, so
# a PR adding a top-level yaml.py would run code in the required `gate` job.
# Start python only from an empty temp dir (ROOT is absolute) and safe-path it.
SAFE_DIR="$(mktemp -d)"
trap 'rm -rf "$SAFE_DIR"' EXIT
cd "$SAFE_DIR" || exit 1
export PYTHONSAFEPATH=1

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FAIL: python3 PyYAML is required (pip install pyyaml)"
  exit 1
fi

ROOT="$ROOT" python3 - <<'PY'
import os, re, stat, sys
import yaml

ROOT = os.environ["ROOT"]
TD = os.path.join(ROOT, ".github", "scripts", "__tests__")
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
check("job-scoped permissions: statuses write + contents/pull-requests/issues read (file list + override re-verify), nothing else",
      rec.get("permissions") == {"contents": "read", "pull-requests": "read", "issues": "read", "statuses": "write"})
check("display name is not the required context name", rec.get("name") == "record opus verdict")
check("runs on a LITERAL ubuntu-latest (a statuses:write job never shares a persistent runner with PR-influenced jobs)",
      rec.get("runs-on") == "ubuntu-latest")
rsteps2 = rec.get("steps", [])
DEFBR = "${{ github.event.repository.default_branch }}"
check("checks out the DEFAULT BRANCH tip (never github.base_ref: side-branch script forgery), never base.sha, never the PR head",
      any("actions/checkout" in s.get("uses", "") and s.get("with", {}).get("ref") == DEFBR for s in rsteps2)
      and "base_ref" not in str([s.get("with", {}) for s in rsteps2]) and "base.ref" not in str([s.get("with", {}) for s in rsteps2])
      and "pull_request.base.sha" not in str(rsteps2) and "head" not in str([s.get("with", {}).get("ref") for s in rsteps2]))
post = [s for s in rsteps2 if "post_opus_verdict_recorded.sh" in s.get("run", "")]
check("posts through post_opus_verdict_recorded.sh with GITHUB_TOKEN (creator github-actions[bot])",
      len(post) == 1 and post[0].get("env", {}).get("GH_TOKEN") == "${{ secrets.GITHUB_TOKEN }}")
check("passes PR-derived values through env, never inline in the run: script",
      len(post) == 1 and "${{" not in post[0]["run"]
      and post[0]["env"].get("BINDING_VERDICT") == "${{ needs.opus-gate.outputs.binding_verdict }}"
      and post[0]["env"].get("PR_NUMBER") == "${{ github.event.pull_request.number }}")
check("passes BASE_REF + DEFAULT_BRANCH (the post script mints a status only for a PR into the default branch), PR_UPDATED_AT and the allowlist",
      len(post) == 1 and post[0]["env"].get("BASE_REF") == "${{ github.base_ref }}"
      and post[0]["env"].get("DEFAULT_BRANCH") == DEFBR
      and post[0]["env"].get("PR_UPDATED_AT") == "${{ github.event.pull_request.updated_at }}"
      and post[0]["env"].get("TIER_B_RELEASE_ACTORS") == "${{ vars.TIER_B_RELEASE_ACTORS }}")

print("--- the recorder runs no PR-controlled non-CI code and re-derives the floor itself ---")
FORBIDDEN = re.compile(r"\b(npm|npx|pnpm|yarn|bun|bunx|make|node|pip3?|python3?|pytest|jest|vitest|cargo|go|mvn|gradle)\b|node_modules|package\.json|Makefile")
def code_lines(path):
    out = []
    for line in open(path).read().splitlines():
        t = line.strip()
        if not t or t.startswith("#"):
            continue
        out.append(t)
    return "\n".join(out)
uses = [s.get("uses", "") for s in rsteps2 if s.get("uses")]
check("the recorder's only `uses:` is actions/checkout (no setup-node, no composite/third-party action)",
      uses and all(u.startswith("actions/checkout@") for u in uses))
ck = [s for s in rsteps2 if "actions/checkout" in s.get("uses", "")]
check("the recorder checkout is sparse to .github/scripts only (no node_modules, no repo tree) with no persisted credentials",
      len(ck) == 1 and ck[0].get("with", {}).get("sparse-checkout") == ".github/scripts"
      and ck[0]["with"].get("persist-credentials") is False)
check("no recorder step sets working-directory or an `env` NODE_OPTIONS/BASH_ENV style injection",
      not any("working-directory" in s or any(k in ("NODE_OPTIONS", "BASH_ENV", "ENV", "LD_PRELOAD") for k in s.get("env", {})) for s in rsteps2))
check("no recorder `run:` invokes a package manager, make, node/python or a test runner",
      all(not FORBIDDEN.search(s.get("run", "")) for s in rsteps2))
for name in ("post_opus_verdict_recorded.sh", "gh_retry.sh", "ci_surface_paths.sh", "verify_human_approved.sh"):
    check(f"{name} (executed by the recorder) uses no package manager, make, node/python or test runner",
          not FORBIDDEN.search(code_lines(os.path.join(SC, name))))
postsrc = open(os.path.join(SC, "post_opus_verdict_recorded.sh")).read()
check("post_opus_verdict_recorded.sh re-derives the file list from the API (pulls/<n>/files, paginated, previous_filename)",
      'pulls/${PR}/files' in postsrc and "--paginate" in postsrc and "previous_filename" in postsrc)
check("the floor posts the exact FLOOR description and is decided BEFORE the success allowlist",
      "FLOOR: CI-surface change — human release required" in postsrc
      and postsrc.index('if [ -n "$FLOOR_DESC" ]') < postsrc.index('elif [ "$RESULT" = "success"'))
check("post_opus_verdict_recorded.sh posts NOTHING unless BASE_REF == DEFAULT_BRANCH (and fails closed if either is unset)",
      'if [ "$BASE" != "$DEFAULT" ]; then' in postsrc and 'if [ -z "$BASE" ] || [ -z "$DEFAULT" ]; then' in postsrc
      and postsrc.index('if [ "$BASE" != "$DEFAULT" ]; then') < postsrc.index("fetch_pr_files()")
      and postsrc.index('if [ "$BASE" != "$DEFAULT" ]; then') < postsrc.index("-X POST"))
check("a claimed human-override is RE-VERIFIED before it is left in place (adder allowlist, label present, live head, approval newer than the event)",
      "override_is_verified" in postsrc and "verified_human_approved_adder" in postsrc
      and '[ "$live_sha" = "$HEAD_SHA" ]' in postsrc and 'grep -qx "$LABEL"' in postsrc
      and '[ "$label_n" -gt "$event_n" ]' in postsrc
      and re.search(r"if override_is_verified; then\s+echo [^\n]*\n\s+exit 0", postsrc) is not None)
check("the recorder takes NO file list from the event payload or an upstream output",
      "changed_files" not in str(rsteps2) and "files" not in str([s.get("env", {}) for s in rsteps2]).lower())

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
writeall = []
for fn in sorted(os.listdir(WF)):
    if not fn.endswith((".yml", ".yaml")):
        continue
    _, doc = load(fn)
    if doc.get("permissions") == "write-all":
        writeall.append(fn)
    for jid, job in (doc.get("jobs") or {}).items():
        if job.get("permissions") == "write-all":
            writeall.append(f"{fn}:{jid}")
check("no workflow or job uses the blanket `write-all` permission shorthand (it would carry statuses: write)", writeall == [])
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
check("runs only for a PR whose base IS the default branch (statuses are SHA-global)",
      "github.event.pull_request.base.ref == github.event.repository.default_branch" in cond)
check("checks out the DEFAULT BRANCH tip (never base.ref / base.sha / the PR head), non-cancelling concurrency per PR and head sha",
      any(s.get("with", {}).get("ref") == DEFBR for s in ov.get("steps", []))
      and "base.ref" not in str([s.get("with", {}) for s in ov.get("steps", [])])
      and not any("base.sha" in str(s.get("with", {})) or "head" in str(s.get("with", {}).get("ref", "")) for s in ov.get("steps", []))
      and ov.get("concurrency", {}).get("cancel-in-progress") is False
      and "pull_request.number" in ov["concurrency"]["group"] and "head.sha" in ov["concurrency"]["group"])
ost = [s for s in ov.get("steps", []) if "record_human_opus_override.sh" in s.get("run", "")]
check("runs record_human_opus_override.sh with PR values env-passed and GITHUB_TOKEN only",
      len(ost) == 1 and "${{" not in ost[0]["run"] and ost[0]["env"].get("GH_TOKEN") == "${{ secrets.GITHUB_TOKEN }}"
      and ost[0]["env"].get("EVENT_HEAD_SHA") == "${{ github.event.pull_request.head.sha }}")
types = (arm.get(True, arm.get("on", {})).get("pull_request_target") or {}).get("types")
check("the trigger did not widen: no `unlabeled`-driven release", types == ["opened", "ready_for_review", "labeled"])
check("runs on a LITERAL ubuntu-latest (never a persistent self-hosted runner)",
      ov.get("runs-on") == "ubuntu-latest")

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
check("ci.yml is read-only (workflow-level permissions: contents: read) and its checkout persists no credentials",
      ci.get("permissions") == {"contents": "read"}
      and all(s.get("with", {}).get("persist-credentials") is False for s in cisteps if "actions/checkout" in s.get("uses", "")))
cirun = "\n".join(s.get("run", "") for s in cisteps if ".github/scripts/__tests__/*.test.sh" in s.get("run", ""))
check("ci.yml starts python only from an empty temp dir with PYTHONSAFEPATH=1 (no top-level yaml.py / pip.py hijack by a non-CI PR)",
      "export PYTHONSAFEPATH=1" in cirun and 'cd "$SAFE_DIR" && python3 -c' in cirun
      and 'cd "$SAFE_DIR" && python3 -m pip' in cirun
      and not re.search(r"^\s*python3 -c", cirun, re.M) and "PYTHONSAFEPATH=1" in open(os.path.join(TD, "gate_binding_conventions.test.sh")).read())
print("--- reviewer sandbox: scripts that decide the verdict are re-fetched + run scrubbed ---")
def trusted_steps(job):
    st = job["steps"]
    ids = [i for i, x in enumerate(st) if x.get("name", "").startswith("Fetch ") and "default branch tip" in x.get("name", "")]
    return st, ids
for jid, last_ids, scriptname in (("review", ["conclude"], "gate_review_conclude.sh"), ("opus-gate", ["binding", "conclude"], "gate_binding_verdict.sh")):
    st, ids = trusted_steps(jobs[jid])
    first_final = min(i for i, x in enumerate(st) if x.get("id") == last_ids[0])
    ok = len(ids) == 1
    if ok:
        f = st[ids[0]]
        ok = (ids[0] < first_final and st[ids[0] - 1].get("run") == "rm -rf .gate-trusted"
              and f["with"].get("ref") == DEFBR and f["with"].get("path") == ".gate-trusted"
              and f["with"].get("persist-credentials") is False and f["with"].get("sparse-checkout") == ".github/scripts"
              and norm_if(f.get("if")) == "always()")
    check(f"{jid}: a fresh default-branch copy of the scripts is fetched AFTER the model steps into a cleaned .gate-trusted dir", ok)
    fin = next(x for x in st if x.get("id") == last_ids[0] and "run" in x and scriptname in x["run"])
    check(f"{jid}: {scriptname} runs from .gate-trusted under `env -i ... bash --noprofile --norc`",
          f".gate-trusted/.github/scripts/{scriptname}" in fin["run"] and "env -i PATH=/usr/bin:/bin" in fin["run"]
          and "bash --noprofile --norc" in fin["run"])
import json
with open(os.path.join(ROOT, ".claude", "settings.json")) as sf:
    allow = json.load(sf).get("permissions", {}).get("allow", [])
check("committed .claude/settings.json does not blanket-allow Bash (the explicit GATE_REVIEWER_ALLOWED_TOOLS list must govern the reviewer)",
      "Bash" not in allow and not any(a.startswith("Bash(*") or a == "Bash(*)" for a in allow))
dep = [s for s in rsteps2 if "post_opus_verdict_recorded.sh" in s.get("run", "")]
check("the recorder floor needs PR_NUMBER (live file list) — passed to the post script",
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

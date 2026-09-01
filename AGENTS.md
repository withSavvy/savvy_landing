# savvy_landing — Agent Instructions

Marketing site for Savvy (static HTML, deployed to Cloudflare via
`wrangler.jsonc`). Part of the savvy_v1 multi-repo workspace — canonical
agent instructions and the work-order bank live in
`withSavvy/savvy-workspace` (`AGENTS.md`, `.claude/docs/`).

## First-principles thinking — the default working mode (Sara, 2026-09-01)

**All work here is done from first-principles thinking.** This governs
*method*, not priority — the constraints below still rank the work.

Decompose to a **primitive you can check** (the row, the line, the CI log, the
status code), then reason back up from it rather than pattern-matching to what
a similar task looked like. What you derive from scratch is the **conclusion**,
never the **code** — reuse libraries, patterns and prior work freely; never
reuse a *claim* unchecked.

1. **Ground every claim in a primitive you personally checked** — not "the doc
   says", not "the PR body says checks are green", not "the last session
   concluded", not "the sub-agent reported".
2. **Interrogate the task before executing it.** A work order's brief is a
   *hypothesis about a fix*, not the fix. If the ask and the real problem have
   come apart, say so in one sentence, then deliver the ask as written under a
   stated assumption — scope stays Sara's call.
3. **Root-cause it, or label it a mitigation** in the PR body. "Flake", "race",
   "transient" are labels, not causes.
4. **Existing patterns are evidence, not authority.** Match them by default;
   when a convention is what makes the task hard, name the constraint that
   produced it and check it still holds. Never rewrite working code on taste
   alone, and never widen a PR.
5. **An earlier session's precedent is the weakest evidence in the building.**
   Docs, memory and hand-offs go stale silently — **when a doc and the tree
   disagree, the tree wins, and the doc gets fixed in the same session.**
6. **Label your epistemic state** — **Verified** (ran it, here is the output) /
   **Derived** (follows from something verified) / **Assumed** (unchecked, and
   here is what breaks if it's wrong).
7. **Delegated work is claimed work** — the parent re-derives every sub-agent
   finding against a primitive before acting on it.

**Smells that mean the rule is being skipped:** `should be fine` ·
`presumably` · `the docs say` · `it worked last time` · `probably a flake` ·
`the PR says checks are green`. Each is a claim standing where a primitive
belongs.

Full spec: `.claude/docs/first-principles-thinking.md` in
`withSavvy/savvy-workspace`.

## Filing work orders (batches are never implemented in-session)

Standing rule (Sara, 2026-07-17): when Sara hands over a batch of tasks, do
NOT implement them here — split the batch into **atomic work orders** (one
per self-contained task) and file each into the work bank on
`withSavvy/savvy-workspace`. The VM picks banked orders up automatically.

Intake is workflow-dispatch ONLY — never push to that repo's main, never
edit its files to file an order:

```bash
gh api -X POST repos/withSavvy/savvy-workspace/actions/workflows/board-action.yml/dispatches --input - <<'JSON'
{"ref":"main","inputs":{"action":"create","title":"TITLE","brief":"BRIEF — what needs doing and why","lane":"implementer","model":"sonnet","actor":"YOUR-AGENT-NAME"}}
JSON
```

Then watch that run to `success` AND verify the
`chore(bank): self-serve create order <slug>` commit exists on
savvy-workspace main before reporting (slug = title lowercased, runs of
non-alphanumerics → one hyphen, ends trimmed, max 80 chars). If either
check fails, report exactly "dispatched but not yet confirmed on main" —
never invent a slug or commit SHA. Full procedure (incl. the GitHub-MCP
variant for sessions without `gh`):
`.claude/docs/work-order-submission.md` in savvy-workspace.

## No loose items — every item raised gets a disposition

Standing rule (Sara, 2026-08-05): a session never carries a loose item.

- **Open a ledger at session start** — every discrete ask in the task/order
  brief, plus anything the previous session's TL;DR left open.
- **Log every new item the moment it appears** — including asides, things you
  discover mid-task, review comments, CI failures, and suggestions *you* raise.
  Your own "we should probably also…" is the item most likely to vanish.
- **Drain the ledger before the session ends.** Each item finishes at exactly
  one of three dispositions:
  1. **Addressed** — done *and verified*; the proof is the pushed diff or a CI
     check green on the pushed commit. A green local run is evidence, not
     proof, and "I made the edit" is neither.
  2. **Captured** — written into a durable location someone can pick up cold: a
     work order filed via the self-serve intake described in this file, or a
     self-contained prompt in the PR body or handoff note. Never the session
     transcript alone — that dies with the container.
  3. **Answered** — consciously declined, deferred, or resolved as a non-issue,
     with one sentence of why.

There is no fourth bucket, and "mentioned it once" is not a disposition. Since
Captured and Answered are always available, running out of session is never a
reason to leave an item loose. The session-end TL;DR (Done / To do / Next) is
written **from the drained ledger**, not from memory.

Full spec: `.claude/docs/no-loose-items.md` in `withSavvy/savvy-workspace`.

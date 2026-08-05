# savvy_landing — Agent Instructions

Marketing site for Savvy (static HTML, deployed to Cloudflare via
`wrangler.jsonc`). Part of the savvy_v1 multi-repo workspace — canonical
agent instructions and the work-order bank live in
`withSavvy/savvy-workspace` (`AGENTS.md`, `.claude/docs/`).

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
  1. **Addressed** — done *and verified*; the pushed diff or passing check is
     the proof, not "I made the edit".
  2. **Captured** — turned into a durable prompt someone can pick up cold: a
     work order filed via the self-serve intake described in this file, or a
     self-contained prompt written into the PR/handoff.
  3. **Answered** — consciously declined, deferred, or resolved as a non-issue,
     with one sentence of why.

There is no fourth bucket, and "mentioned it once" is not a disposition. Since
Captured and Answered are always available, running out of session is never a
reason to leave an item loose. The session-end TL;DR (Done / To do / Next) is
written **from the drained ledger**, not from memory.

Full spec: `.claude/docs/no-loose-items.md` in `withSavvy/savvy-workspace`.

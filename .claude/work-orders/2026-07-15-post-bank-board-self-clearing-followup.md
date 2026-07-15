# Post-Overnight Follow-up Work Orders
_Banked: 2026-07-15 · Session: bank-board-self-clearing overnight monitoring_

These items surfaced during the 2026-07-14/15 overnight watch of the savvy-workspace
build pipeline and were not resolved before token exhaustion.

---

## WO-1 · Burn/heartbeat telemetry fix

**Slug:** `fix-vm-burn-heartbeat-telemetry`  
**Status:** QUEUED  
**Priority:** P2

`cron-vm-burn-push.log` and `cron-env-status-heartbeat.log` are both empty even
though the crons fire on schedule (confirmed via `crontab -l` + log mtime). The
scripts exit without writing anything — not silently failing, just producing zero
output to the log target.

**Diagnosis starting point (VM, savvy_v1):**
```bash
bash /root/savvy_v1/.claude/scripts/env-status-heartbeat.sh; echo "exit=$?"
bash /root/savvy_v1/.claude/scripts/cron-vm-burn-push.sh; echo "exit=$?"
```

Check whether the scripts redirect stdout/stderr to the log file or rely on the
cron's output capture, and whether the log target path matches what the cron job
expects.

---

## WO-2 · board:drain-status KV / Cloudflare Worker deploy

**Slug:** `deploy-board-drain-status-worker`  
**Status:** QUEUED  
**Priority:** P2

`drain-status.json` lives in the VM's HOME state dir (written every coordinator
tick). `board-kv-upload.sh` wraps it into the KV sidecar `board:drain-status.js`
(`window.DRAIN_STATUS`), but the Cloudflare Worker that serves this sidecar has
not been deployed. Without it, drain-status is invisible remotely — the board
can't reflect coordinator state, and overnight monitoring requires direct VM SSH.

**What to do:** Deploy `board-kv-upload.sh`'s companion Worker. The board Worker
logic + `board-kv-upload.sh` are already written in savvy_v1. This is a deploy
step, not a code change.

---

## WO-3 · board-create-verify false positive — widen or slug-check

**Slug:** `fix-board-create-verify-false-positive`  
**Status:** QUEUED  
**Priority:** P3

`board-create-verify` fires ~7 min after a board create and raises a GitHub issue
if it can't find the order in the bank. Two false positives observed this session:

- **#1306 → #1305**: order landed as #1305 at 00:02Z; verify fired at 00:09Z
  (7 min) and filed #1306 claiming it was lost. Closed as `not_planned`.
- **#1299 → #1296**: same pattern, earlier run.

Root cause: the 7-min window races a squash-merge timing edge. The verify script
checks for the order *at exactly* its deadline, which sometimes precedes the
bank-fallback-PR squash landing in main.

**Fix options (pick one):**
1. Widen the wait window from 7 min → 12 min before calling it lost.
2. Before filing, check `origin/main` for the order slug directly (a `git log
   --grep` or a grep of `work-orders.html`) so an already-landed order is never
   flagged as missing.

Option 2 is more robust; option 1 is a one-liner.

---

## WO-4 · Triage daily cap review

**Slug:** `review-triage-daily-cap`  
**Status:** QUEUED  
**Priority:** P3

Alex triage lane runs at `*/15` and is capped at 8 judgements/day. As of
2026-07-15 the `needsTriage` backlog was ~34 orders (~4+ days to drain at 8/day).
During the overnight the cap was exhausted by ~18:31Z, leaving parks #1292,
#1298, #1301, #1303 without specs (they expire by ~20:04Z same day — OPENAI fix
from #1304 handles the auth; the parks may need manual re-queuing if already
expired).

**What to do:**
- Confirm whether 8/day is intentional (subscription contention guard) or
  conservative now that the OPENAI_API_KEY source is fixed (#1304).
- If contention has subsided, bump `TRIAGE_DAILY_CAP` in `run-alex-triage.sh`
  (or the config it reads) to drain the backlog faster.
- Check whether the four expired parks from 2026-07-15 auto-re-queued or need
  a manual `set-status needsTriage` pass.

---

## WO-5 · Verify two 18:09Z build states (housekeeping)

**Slug:** `verify-18-09-builds-resolved`  
**Status:** QUEUED  
**Priority:** P4 (informational / close-out)

Two builds entered the coordinator at ~18:09Z on 2026-07-14 and were never
confirmed resolved from GitHub. The coordinator was alive (drain-status.json was
fresh 9 seconds before the check), so they almost certainly closed normally. But
no merged PR, quarantine issue, or stale-claim release commit was found on the
GitHub side for that window.

**Confirm with:**
```bash
cat /root/.claude/scheduled-tasks/state/drain-status.json
```
If `activeSlots` is empty and no IN_PROGRESS orders have a `claimedAt` near
18:09Z, they resolved cleanly and this work order can be closed immediately.

---

_Done this session (no action needed):_
- ~~**AUTOMATION_ANTHROPIC_API_KEY retirement**~~ — merged as #51
- ~~**Gate migration to savvy-gate-bot App**~~ — merged as #53
- ~~**Self-hosted runner for landing deploy**~~ — merged as #52
- ~~**OPENAI_API_KEY triage fix**~~ — merged as #1304 (savvy-workspace)

---
name: usage-guard
description: Stand down the lead and every Agent Teams teammate when plan-usage headroom is low, notify, and schedule an automatic resume one minute after the limit resets. The STANDDOWN protocol is triggered automatically by the usage-guard Stop hook on breach; the RESUME protocol is triggered by the one-shot cron the standdown schedules.
---

# usage-guard: quota stand-down & resume

The lead orchestrates. Subagents (one-shot Agent-tool runs) are NOT touched — let them finish and return. Only the **lead** and **teammates** stand down and resume.

Get fresh numbers any time with `bash ~/.claude/usage-guard/guard.sh` (JSON verdict: `breach`, `remaining_5h`, `stop_at_remaining`, `window`, `wake_at_epoch`, `wake_at_iso`, `seconds_until_wake`).

## STANDDOWN — run once when the Stop hook flags a breach, then stop

1. **Numbers.** From the verdict compute `resume` = local `HH:MM` (add the date if not today) of `wake_at_epoch`, and `N` = count of active teammates (`TaskList` → distinct named owners).
2. **Notify.** `PushNotification` (status `proactive`): `usage-guard: 5h <rem>% <= <limit>% — standing down lead + <N> teammates, resume <resume>`.
3. **Teammates.** For each active teammate:
   - `SendMessage` to it: `usage-guard standdown: quota low, pausing until ~<resume>. Save state; I'll re-send your task on resume.`
   - Reconcile its ledger entry (no task left `in_progress`).
   - `TaskStop` it.
4. **Checkpoint.** Write the **session-scoped** roster file the Stop-hook directive gave you — `~/.claude/usage-guard/resume-<session_id>.json`, never a shared `resume.json` (concurrent sessions would clobber each other). Leave `resume_cron_id` null for now — you fill it in step 5:
   `{ "goal": "<batch goal>", "wake_at_epoch": <n>, "resume_cron_id": null, "teammates": [ { "name": "...", "role": "...", "task": "...", "worktree": "...", "branch": "..." } ] }`
5. **Schedule the resume** — local, session-only, minute-accurate, single fire. Read `wake_at_iso` from the verdict (local ISO, e.g. `2026-07-18T01:01:00`) and map it straight to a 5-field cron `minute hour day-of-month month day-of-week`, adding ~1 min so it fires just AFTER the reset (day-of-week stays `*`). **Don't eyeball the format — call it exactly like this** (worked example for `wake_at_iso` = `2026-07-18T01:01:00` → fire 01:02):
   `CronCreate({ cron: "2 1 18 7 *", recurring: false, prompt: "Invoke the usage-guard skill and run its RESUME protocol. Read ~/.claude/usage-guard/resume-<session_id>.json; if it is absent the stand-down was cancelled — stop. Otherwise re-verify with guard.sh; if still breaching re-schedule ~5 min out, else resume, then delete resume-<session_id>.json + standdown-<session_id>.json." })`
   Then write the id `CronCreate` returns back into `resume-<session_id>.json` as `resume_cron_id`, so CANCEL can delete the exact job deterministically — even if this conversation is later compacted and the id falls out of context.
6. **Stop.** Do no further work. The session goes idle until the cron fires — this is what lets the lead itself resume without any OS scheduler.

## RESUME — run when the scheduled cron fires

1. **Cancelled?** If this session's `resume-<session_id>.json` is absent, the stand-down was cancelled (see CANCEL) — do nothing and stop. The cron fired into a no-op; that is expected.
2. **Re-verify.** `bash ~/.claude/usage-guard/guard.sh`. If still `breach:true` (the window hasn't actually reset yet), re-`CronCreate` ~5 min out and stop.
3. **Notify.** `PushNotification`: `usage-guard: limits reset — resuming lead + <N> teammates.`
4. **Rehydrate teammates.** Read this session's `resume-<session_id>.json`. For each teammate: re-spawn it (`Agent`, same role/worktree/branch) if its pane died, or `SendMessage` its pending task if it is still alive. Restore the ledger.
5. **Clean up.** Delete this session's `resume-<session_id>.json` and `standdown-<session_id>.json` only — never another session's files.
6. **Continue** the batch from where it stood down.

## CANCEL — abort a pending stand-down on request

Run when the user asks to cancel the resume / not stand down after all.

1. **Drop the checkpoint + mute.** `bash ~/.claude/usage-guard/cancel.sh <session_id>` — clears this session's `standdown-<session_id>.json` + `resume-<session_id>.json` (the status line pause clears) and writes an `off-<session_id>` mute so the session does not immediately stand down again while still in breach.
2. **Drop the resume cron.** `cancel.sh` prints the checkpoint's `resume_cron_id` before it clears the file — `CronDelete` that exact id, no guessing (or read it from `resume-<session_id>.json` yourself if you skipped `cancel.sh`). Session-only crons can be deleted **only from the window that created them**: from any other window, close that window to kill its cron instead. Either way this is best-effort — with the checkpoint gone, an orphaned cron just fires into a no-op (RESUME aborts at step 1).
3. **Re-arm later** by removing the mute: `rm ~/.claude/usage-guard/off-<session_id>`.

Never call the usage API directly — `guard.sh` only reads the cache `claude-plan-usage-statusline` maintains.

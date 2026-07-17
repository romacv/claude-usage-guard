---
name: usage-guard
description: Stand down the lead and every Agent Teams teammate when plan-usage headroom is low, notify, and schedule an automatic resume one minute after the limit resets. The STANDDOWN protocol is triggered automatically by the usage-guard Stop hook on breach; the RESUME protocol is triggered by the one-shot cron the standdown schedules.
---

# usage-guard: quota stand-down & resume

The lead orchestrates. Subagents (one-shot Agent-tool runs) are NOT touched — let them finish and return. Only the **lead** and **teammates** stand down and resume.

Get fresh numbers any time with `bash ~/.claude/usage-guard/guard.sh` (JSON verdict: `remaining_5h`, `stop_at_remaining`, `window`, `wake_at_epoch`, `seconds_until_wake`).

## STANDDOWN — run once when the Stop hook flags a breach, then stop

1. **Numbers.** From the verdict compute `resume` = local `HH:MM` (add the date if not today) of `wake_at_epoch`, and `N` = count of active teammates (`TaskList` → distinct named owners).
2. **Notify.** `PushNotification` (status `proactive`): `usage-guard: 5h <rem>% <= <limit>% — standing down lead + <N> teammates, resume <resume>`.
3. **Teammates.** For each active teammate:
   - `SendMessage` to it: `usage-guard standdown: quota low, pausing until ~<resume>. Save state; I'll re-send your task on resume.`
   - Reconcile its ledger entry (no task left `in_progress`).
   - `TaskStop` it.
4. **Checkpoint.** Write the **session-scoped** roster file the Stop-hook directive gave you — `~/.claude/usage-guard/resume-<session_id>.json`, never a shared `resume.json` (concurrent sessions would clobber each other):
   `{ "goal": "<batch goal>", "wake_at_epoch": <n>, "teammates": [ { "name": "...", "role": "...", "task": "...", "worktree": "...", "branch": "..." } ] }`
5. **Schedule the resume** — local, session-only, minute-accurate, single fire:
   `CronCreate` with `recurring: false`, `cron` pinned to the local minute of `wake_at_epoch` **plus ~1 min** (so it fires AFTER the reset), `prompt: "Invoke the usage-guard skill RESUME protocol; read resume-<session_id>.json."`
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
2. **Drop the resume cron.** `CronDelete` the one-shot resume job you scheduled in STANDDOWN, if you still hold its id. If you don't, no action is needed — with the checkpoint gone, RESUME aborts at step 1 when the cron fires.
3. **Re-arm later** by removing the mute: `rm ~/.claude/usage-guard/off-<session_id>`.

Never call the usage API directly — `guard.sh` only reads the cache `claude-plan-usage-statusline` maintains.

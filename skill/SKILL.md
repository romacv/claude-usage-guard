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
4. **Checkpoint.** Write `~/.claude/usage-guard/resume.json`:
   `{ "goal": "<batch goal>", "wake_at_epoch": <n>, "teammates": [ { "name": "...", "role": "...", "task": "...", "worktree": "...", "branch": "..." } ] }`
5. **Schedule the resume** — local, session-only, minute-accurate, single fire:
   `CronCreate` with `recurring: false`, `cron` pinned to the local minute of `wake_at_epoch` **plus ~1 min** (so it fires AFTER the reset), `prompt: "Invoke the usage-guard skill RESUME protocol."`
6. **Stop.** Do no further work. The session goes idle until the cron fires — this is what lets the lead itself resume without any OS scheduler.

## RESUME — run when the scheduled cron fires

1. **Re-verify.** `bash ~/.claude/usage-guard/guard.sh`. If still `breach:true` (the window hasn't actually reset yet), re-`CronCreate` ~5 min out and stop.
2. **Notify.** `PushNotification`: `usage-guard: limits reset — resuming lead + <N> teammates.`
3. **Rehydrate teammates.** Read `resume.json`. For each teammate: re-spawn it (`Agent`, same role/worktree/branch) if its pane died, or `SendMessage` its pending task if it is still alive. Restore the ledger.
4. **Clean up.** Delete `resume.json` and `~/.claude/usage-guard/standdown.json`.
5. **Continue** the batch from where it stood down.

Never call the usage API directly — `guard.sh` only reads the cache `claude-plan-usage-statusline` maintains.

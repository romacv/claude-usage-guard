---
name: usage-guard
description: CLAUDE CODE ONLY. Stand down the lead and every Agent Teams teammate when plan-usage headroom is low, notify, and schedule an automatic resume one minute after the limit resets. The STANDDOWN protocol is triggered automatically by the usage-guard Stop hook on breach; the RESUME protocol is triggered by the one-shot cron the standdown schedules.
---

# usage-guard: quota stand-down & resume

> **Claude Code only.** This skill sits in the shared tree because the tree is shared
> by all three runtimes, but only Claude Code can execute it: it depends on
> `~/.claude/usage-guard/` (`guard.sh`, `cancel.sh`, the Stop hook), on `CronCreate`,
> `PushNotification`, `TaskList`/`TaskGet`, and on Agent Teams panes. **If you are
> Codex or Antigravity, skip this skill** — report the quota limit to the User as a
> blocker and do not reimplement the protocol with your own primitives.

The lead orchestrates. Subagents (one-shot Agent-tool runs) are NOT touched — let them finish and return. Only the **lead** and **teammates** stand down and resume.

Get fresh numbers any time with `bash ~/.claude/usage-guard/guard.sh` (JSON verdict: `breach`, `window` (`5h`, `7d`, or `5h+7d`), `remaining_5h`, `remaining_7d`, `stop_at_remaining`, `wake_at_epoch`, `wake_at_iso`, `seconds_until_wake`).

## STANDDOWN — run once when the Stop hook flags a breach, then stop

1. **Numbers.** Take `resume` from **this session's stand-down marker** `~/.claude/usage-guard/standdown-<session_id>.json` — its `wake_at_epoch`/`wake_at_iso` already include any **deferral push** (+5 min per breach warning you ignored before standing down), so the cron lands on the real, pushed time, not a fresh guard.sh reading. Compute `resume` = local `HH:MM` (add the date if not today) of that `wake_at_epoch`, and `N` = count of active teammates (`TaskList` → distinct named owners). (The injected Stop-hook directive already states this pushed `resume` — use it.)
2. **Notify.** `PushNotification` (status `proactive`): `usage-guard: <window> <rem>% <= <limit>% — standing down lead + <N> teammates, resume <resume>` — take `<window>` and its remaining from the marker's `window`/`remaining_*` (the breached window, not always `5h`).
3. **Teammates — pause, don't kill.** A quota limit is not death: keep each teammate's pane **alive and idle** so on resume it continues from its own transcript, never a lossy re-spawn from the checkpoint summary. For each active teammate:
   - `SendMessage` to it: `usage-guard standdown: quota low, pausing until ~<resume>. Finish your current turn, save state, then go idle — do NOT start new work. I'll re-send your task on resume.`
   - `TaskGet` its current task and capture the FULL state — subject, description, progress so far — into the checkpoint's `task` field (a name alone is not enough): if the pane dies before resume, the fallback re-spawn can only paste back what the checkpoint holds.
   - Reconcile its ledger entry (no task left `in_progress`).
   - Leave the pane running (idle). Do **not** `TaskStop` it. `TaskStop` is a fallback only when a pane is already dead/unresponsive — killing a live pane discards all in-context state and forces a re-spawn, which is exactly the loss this protocol exists to prevent.
4. **Schedule the resume** — local, session-only, minute-accurate, single fire. Do this **before** the checkpoint so the cron's id goes into it in one write (no second edit). Read `wake_at_iso` from **this session's stand-down marker** `standdown-<session_id>.json` (local ISO, e.g. `2026-07-18T01:01:00`; it carries the deferral push — do NOT re-read a fresh guard.sh verdict, which would drop it) and map it straight to a 5-field cron `minute hour day-of-month month day-of-week`, adding ~1 min so it fires just AFTER the reset (day-of-week stays `*`). **Don't eyeball the format — call it exactly like this** (worked example for `wake_at_iso` = `2026-07-18T01:01:00` → fire 01:02):
   `CronCreate({ cron: "2 1 18 7 *", recurring: false, prompt: "Invoke the usage-guard skill and run its RESUME protocol. Read ~/.claude/usage-guard/resume-<session_id>.json; if it is absent the stand-down was cancelled — stop. Otherwise re-verify with guard.sh; if still breaching increment resume_retries and re-schedule ~5 min out (after 3 retries stop and PushNotification instead of looping), else resume, then delete resume-<session_id>.json + standdown-<session_id>.json." })`
5. **Checkpoint** — **one write, no follow-up edit.** First reconcile **your own** in-progress ledger task too — the "no task ends `in_progress`" invariant applies to the lead, not only teammates — and record it as `lead_task`, so your own work doesn't read as abandoned on resume. Then write the **session-scoped** roster file the Stop-hook directive gave you — `~/.claude/usage-guard/resume-<session_id>.json`, never a shared `resume.json` (concurrent sessions would clobber each other) — with `resume_cron_id` already set to the id step 4 returned and `resume_retries` at 0, so CANCEL can delete the exact job deterministically even after a context compaction:
   `{ "goal": "<batch goal>", "wake_at_epoch": <n>, "resume_cron_id": "<id from step 4>", "resume_retries": 0, "lead_task": "<your own in-progress task, reconciled + full state>", "teammates": [ { "name": "...", "role": "...", "task": "<full state from TaskGet: subject + description + progress>", "worktree": "...", "branch": "..." } ] }`
6. **Stop.** Do no further work. The session goes idle until the cron fires — this is what lets the lead itself resume without any OS scheduler.

## STANDDOWN (teammate side) — a spawned teammate that hits the breach

Applies when the usage-guard Stop hook flags a breach inside a **teammate's own** session, not the lead's. A teammate never runs the lead machinery (no `PushNotification`, no `CronCreate`, no checkpoint — those are the lead's, once, for the whole team). It only:

1. **Stop.** Finish the current turn, then do NOT pick up the next task or start new work.
2. **Stay open.** Keep the pane **alive and idle** — never self-`TaskStop`. A live pane resumes from this transcript when the lead re-sends the task; killing it would throw away all in-progress state.
3. **Report up — one final message to the lead.** `SendMessage` to the lead exactly once: `paused — approaching quota limit; idle, holding state, awaiting your resume.` Then go idle and wait for the lead's resume message.

The lead's STANDDOWN above still messages every teammate as a backstop, in case a teammate's own Stop hook did not fire.

## RESUME — run when the scheduled cron fires

1. **Cancelled?** If this session's `resume-<session_id>.json` is absent, the stand-down was cancelled (see CANCEL) — do nothing and stop. The cron fired into a no-op; that is expected.
2. **Re-verify (bounded).** `bash ~/.claude/usage-guard/guard.sh`. If still `breach:true` (the window hasn't actually reset yet), increment `resume_retries` in `resume-<session_id>.json` and re-`CronCreate` ~5 min out, then stop — **but cap it:** once `resume_retries` reaches 3, do NOT reschedule again. Instead `PushNotification` (proactive) `usage-guard: resume delayed 3× — still breaching well past reset, check guard.sh / the usage cache manually` and stop, so a stuck or false breach can never silently loop forever.
3. **Notify.** `PushNotification`: `usage-guard: limits reset — resuming lead + <N> teammates.`
4. **Rehydrate teammates.** Read this session's `resume-<session_id>.json`. For each teammate: re-spawn it (`Agent`, same role/worktree/branch) if its pane died, or `SendMessage` its pending task if it is still alive. Restore the ledger.
5. **Clean up.** Delete this session's `resume-<session_id>.json` and `standdown-<session_id>.json` only — never another session's files.
6. **Continue** the batch from where it stood down.

## CANCEL — abort a pending stand-down on request

Run when the user asks to cancel the resume / not stand down after all.

1. **Drop the checkpoint.** `bash ~/.claude/usage-guard/cancel.sh <session_id>` — clears this session's `standdown-<session_id>.json` + `resume-<session_id>.json` (the status line pause clears). There is NO mute: the guard stays armed, so if the session is still in breach the next Stop hook stands down again — intended, the guard cannot be silenced. Cancel is only durable once the breach has actually passed.
2. **Drop the resume cron.** `cancel.sh` prints the checkpoint's `resume_cron_id` before it clears the file — `CronDelete` that exact id, no guessing (or read it from `resume-<session_id>.json` yourself if you skipped `cancel.sh`). Session-only crons can be deleted **only from the window that created them**: from any other window, close that window to kill its cron instead. Either way this is best-effort — with the checkpoint gone, an orphaned cron just fires into a no-op (RESUME aborts at step 1).
3. **No re-arm step** — there is no mute to remove; the guard is always armed.

Never call the usage API directly — `guard.sh` only reads the cache `claude-plan-usage-statusline` maintains.

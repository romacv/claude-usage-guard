---
name: usage-guard
description: CLAUDE CODE ONLY. Stand down the lead session when plan-usage headroom is low, notify, and schedule an automatic resume one minute after the limit resets. The STANDDOWN protocol is triggered automatically by the usage-guard Stop hook on breach; the RESUME protocol is triggered by the one-shot cron the standdown schedules.
---

# usage-guard: quota stand-down & resume

> **Claude Code only.** This skill sits in the shared tree because the tree is shared
> by all three runtimes, but only Claude Code can execute it: it depends on
> `~/.claude/usage-guard/` (`guard.sh`, `cancel.sh`, the Stop hook), `CronCreate`,
> `PushNotification`, and `TaskList`/`TaskGet`. **If you are Codex or Antigravity, skip
> this skill** — report the quota limit to the User as a blocker and do not reimplement
> the protocol with your own primitives.

Subagents (one-shot Agent-tool runs) are NOT touched — let them finish and return.
Only the lead's own session stands down and resumes.

Get fresh numbers any time with `bash ~/.claude/usage-guard/guard.sh` (JSON verdict: `breach`, `remaining_5h`, `remaining_7d`, `stop_at_remaining`, `window` — the breached window(s), `5h`/`7d`/`5h+7d` — `wake_at_epoch`, `wake_at_iso`, `seconds_until_wake`).

## STANDDOWN — run once when the Stop hook flags a breach, then stop

1. **Numbers.** Take `resume` from **this session's stand-down marker** `~/.claude/usage-guard/standdown-<session_id>.json` — its `wake_at_epoch`/`wake_at_iso` already include any **deferral push** (+5 min per breach warning you ignored before standing down), so the cron lands on the real, pushed time, not a fresh guard.sh reading. Compute `resume` = local `HH:MM` (add the date if not today) of that `wake_at_epoch`. (The injected Stop-hook directive already states this pushed `resume` — use it.)
2. **Notify.** `PushNotification` (status `proactive`): `usage-guard: <window> <rem>% <= <limit>% — standing down, resume <resume>` — take `<window>` (`5h`, `7d`, or `5h+7d`) and `<rem>` (the remaining headroom of the tightest breached window) from the injected Stop-hook directive, or from this session's marker's `window`/`remaining_5h`/`remaining_7d`/`stop_at_remaining` fields if composing fresh. Never hardcode `5h` — a `7d` or `5h+7d` breach must report its own window and remaining %.
3. **Schedule the resume** — local, session-only, minute-accurate, single fire. Do this **before** the checkpoint so the cron's id goes into it in one write (no second edit). Read `wake_at_iso` from **this session's stand-down marker** `standdown-<session_id>.json` (local ISO, e.g. `2026-07-18T01:01:00`; it carries the deferral push — do NOT re-read a fresh guard.sh verdict, which would drop it) and map it straight to a 5-field cron `minute hour day-of-month month day-of-week`, adding ~1 min so it fires just AFTER the reset (day-of-week stays `*`). **Don't eyeball the format — call it exactly like this** (worked example for `wake_at_iso` = `2026-07-18T01:01:00` → fire 01:02):
   `CronCreate({ cron: "2 1 18 7 *", recurring: false, prompt: "Invoke the usage-guard skill and run its RESUME protocol. Read ~/.claude/usage-guard/resume-<session_id>.json; if it is absent the stand-down was cancelled — stop. Otherwise re-verify with guard.sh; if still breaching increment resume_retries and re-schedule ~5 min out (after 3 retries stop and PushNotification instead of looping), else resume, then delete resume-<session_id>.json + standdown-<session_id>.json." })`
4. **Checkpoint** — **one write, no follow-up edit.** Reconcile your own in-progress ledger task first — no task ends `in_progress` — and record it as `lead_task`, so your own work doesn't read as abandoned on resume. Then write the **session-scoped** marker the Stop-hook directive gave you — `~/.claude/usage-guard/resume-<session_id>.json`, never a shared `resume.json` (concurrent sessions would clobber each other) — with `resume_cron_id` already set to the id step 3 returned and `resume_retries` at 0, so CANCEL can delete the exact job deterministically even after a context compaction:
   `{ "goal": "<batch goal>", "wake_at_epoch": <n>, "resume_cron_id": "<id from step 3>", "resume_retries": 0, "lead_task": "<your own in-progress task, reconciled + full state>" }`
5. **Stop.** Do no further work. The session goes idle until the cron fires — this is what lets the lead itself resume without any OS scheduler.

## RESUME — run when the scheduled cron fires

1. **Cancelled?** If this session's `resume-<session_id>.json` is absent, the stand-down was cancelled (see CANCEL) — do nothing and stop. The cron fired into a no-op; that is expected.
2. **Re-verify (bounded).** `bash ~/.claude/usage-guard/guard.sh`. If still `breach:true` (the window hasn't actually reset yet), increment `resume_retries` in `resume-<session_id>.json` and re-`CronCreate` ~5 min out, then stop — **but cap it:** once `resume_retries` reaches 3, do NOT reschedule again. Instead `PushNotification` (proactive) `usage-guard: resume delayed 3× — still breaching well past reset, check guard.sh / the usage cache manually` and stop, so a stuck or false breach can never silently loop forever.
3. **Notify.** `PushNotification`: `usage-guard: limits reset — resuming.`
4. **Clean up.** Delete this session's `resume-<session_id>.json` and `standdown-<session_id>.json` only — never another session's files.
5. **Continue** the work from where it stood down, using `lead_task` from the deleted checkpoint to pick the thread back up.

## CANCEL — abort a pending stand-down on request

Run when the user asks to cancel the resume / not stand down after all.

1. **Drop the checkpoint.** `bash ~/.claude/usage-guard/cancel.sh <session_id>` — clears this session's `standdown-<session_id>.json` + `resume-<session_id>.json` (the status line pause clears). There is NO mute: the guard stays armed, so if the session is still in breach the next Stop hook stands down again — intended, the guard cannot be silenced. Cancel is only durable once the breach has actually passed.
2. **Drop the resume cron.** `cancel.sh` prints the checkpoint's `resume_cron_id` before it clears the file — `CronDelete` that exact id, no guessing (or read it from `resume-<session_id>.json` yourself if you skipped `cancel.sh`). Session-only crons can be deleted **only from the window that created them**: from any other window, close that window to kill its cron instead. Either way this is best-effort — with the checkpoint gone, an orphaned cron just fires into a no-op (RESUME aborts at step 1).
3. **No re-arm step** — there is no mute to remove; the guard is always armed.

## Anti-patterns

`/goal` is condition-based; it busy-loops the Stop hook and burns quota every
cycle. For "hold until HH:MM" use a one-shot session cron (`CronCreate`) — the
same primitive usage-guard's own resume uses — and stay idle. Also: `/goal clear`
may surface one stale-condition Stop-hook error afterward (Claude Code internal,
harmless).

Never call the usage API directly — `guard.sh` only reads the cache `claude-plan-usage-statusline` maintains.

---
name: usage-guard
description: CLAUDE CODE ONLY. Stand down the lead session when plan-usage headroom is low, notify, and — only when work is left unfinished — schedule an automatic resume one minute after the limit resets. The STANDDOWN protocol is triggered automatically by the usage-guard Stop hook on breach; the RESUME protocol is triggered by the one-shot resume the standdown schedules (desktop scheduled task, or session cron in the terminal).
---

# usage-guard: quota stand-down & resume

> **Claude Code only.** This skill sits in the shared tree because the tree is shared
> by all three runtimes, but only Claude Code can execute it: it depends on
> `~/.claude/usage-guard/` (`guard.sh`, `cancel.sh`, the Stop hook), `CronCreate` (terminal), `mcp__scheduled-tasks` and `mcp__ccd_session_mgmt` (desktop app),
> `PushNotification`, and `TaskList`/`TaskGet`. **If you are Codex or Antigravity, skip
> this skill** — report the quota limit to the User as a blocker and do not reimplement
> the protocol with your own primitives.

Running subagents (one-shot Agent-tool runs already in flight) are NOT
touched — let them finish and return. Only the lead's own session stands down
and resumes. New subagents are a separate gate: a `PreToolUse` hook on the
`Agent` tool (`pretool-hook.sh`) refuses to spawn one while the same breach is
active, so a dispatch can't keep spending after the lead has stood down.

Get fresh numbers any time with `bash ~/.claude/usage-guard/guard.sh` (JSON verdict: `breach`, `remaining_5h`, `remaining_7d`, `stop_at_remaining`, `window` — the breached window(s), `5h`/`7d`/`5h+7d` — `wake_at_epoch`, `wake_at_iso`, `seconds_until_wake`). A missing or stale cache makes it refresh once (see the last line); an unknown reading (`reason`: `no_cache`/`stale_cache`/...) carries the refresh outcome as `refresh` (`no_token`, `http_401`, `backoff`, `timeout`, ...) and is never a breach.

## STANDDOWN — run once when the Stop hook flags a breach, then stop

1. **Numbers.** Take `resume` from **this session's stand-down marker** `~/.claude/usage-guard/standdown-<session_id>.json` — its `wake_at_epoch`/`wake_at_iso` already include any **deferral push** (+5 min per breach warning you ignored before standing down), so the cron lands on the real, pushed time, not a fresh guard.sh reading. Compute `resume` = local `HH:MM` (add the date if not today) of that `wake_at_epoch`. (The injected Stop-hook directive already states this pushed `resume` — use it.)
2. **Notify.** `PushNotification` (status `proactive`): `usage-guard: <window> <rem>% <= <limit>% — standing down, resume <resume>`, or `… — standing down, nothing queued` when step 3 skips the cron — take `<window>` (`5h`, `7d`, or `5h+7d`) and `<rem>` (the remaining headroom of the tightest breached window) from the injected Stop-hook directive, or from this session's marker's `window`/`remaining_5h`/`remaining_7d`/`stop_at_remaining` fields if composing fresh. Never hardcode `5h` — a `7d` or `5h+7d` breach must report its own window and remaining %.
3. **Schedule the resume — only if there is work to resume.** Decide this first. A cron
   that wakes the session to announce the reset and then sit idle spends a whole turn on
   nothing; that is the same waste as a busy-loop, just once. Ask whether anything
   continues **without** the User: an unfinished task, a build or job to read back, a
   queued next step. If nothing does — his last request is finished and the next move is
   his — **skip this step entirely**: no resume job, `resume_cron_id: null` and `resume_kind: null` in the checkpoint,
   and the shorter notification from step 2. Then **delete `standdown-<session_id>.json`**.
   That file is what the status line renders, and a `⏸paused to HH:MM` badge with no
   cron behind it is a promise nothing keeps; with nothing scheduled there is no pause to
   display. Keep `resume-<session_id>.json` — that one is the Stop hook's latch, so the
   stand-down directive still does not re-fire. Nothing strands: the reaper sweeps a
   wake-less checkpoint by file age after a day, and the next definite no-breach reading
   clears whatever is left. Otherwise schedule one single-fire resume that survives an idle stop. **First clear the previous one:** if `resume-<session_id>.json` already exists, delete the job its `resume_cron_id` names (by its `resume_kind`: `scheduled_task` -> `delete_scheduled_task`, `cron` -> `CronDelete`). A cancelled and re-entered stand-down otherwise leaves that job alive, and overwriting the checkpoint loses the only id that could remove it. Schedule **before** the checkpoint so the new id goes into it in one write. Read `wake_at_iso` from **this session's stand-down marker** `standdown-<session_id>.json` (local ISO with offset; it carries the deferral push — do NOT re-read a fresh guard.sh verdict) and add ~1 min so it fires just AFTER the reset.
   - **Desktop app** (`mcp__scheduled-tasks__create_scheduled_task` available): a session cron dies with the process, and the app's idle sweep stops a session idle ~4 h, so use a scheduled task (stored on disk). Get your own id with `mcp__ccd_session_mgmt__get_session({session_id: "self"})` (`local_...`). Each run starts a fresh session, so the prompt is self-contained: it sends the resume message to the stopped session, which the app restarts. `resume_kind` = `scheduled_task`, `resume_cron_id` = the taskId. Worked example (`wake_at_iso` = `2026-07-18T01:01:00+07:00`, session `abcd1234-...`, own id `local_abc`):
     `create_scheduled_task({ taskId: "usage-guard-resume-abcd1234", description: "usage-guard resume", fireAt: "2026-07-18T01:02:00+07:00", notifyOnCompletion: false, prompt: "If ~/.claude/usage-guard/resume-abcd1234-....json is absent, stop. Otherwise send this message to session local_abc with mcp__ccd_session_mgmt__send_message: 'Invoke the usage-guard skill and run its RESUME protocol.' Do nothing else." })`
   - **Terminal** (no scheduled-tasks tool; terminal processes are not idle-swept): session-only cron. Map the time to a 5-field cron `minute hour day-of-month month day-of-week` (day-of-week `*`). `resume_kind` = `cron`, `resume_cron_id` = the id returned. **Don't eyeball the format — call it exactly like this** (`wake_at_iso` = `2026-07-18T01:01:00` -> fire 01:02):
     `CronCreate({ cron: "2 1 18 7 *", recurring: false, prompt: "Invoke the usage-guard skill and run its RESUME protocol. Read ~/.claude/usage-guard/resume-<session_id>.json; if it is absent the stand-down was cancelled — stop. Otherwise re-verify with guard.sh; if still breaching increment resume_retries and re-schedule ~5 min out (after 3 retries stop and PushNotification instead of looping), else resume, then delete resume-<session_id>.json + standdown-<session_id>.json." })`
4. **Checkpoint** — **one write, no follow-up edit.** Reconcile your own in-progress ledger task first — no task ends `in_progress` — and record it as `lead_task`, so your own work doesn't read as abandoned on resume. Then write the **session-scoped** marker the Stop-hook directive gave you — `~/.claude/usage-guard/resume-<session_id>.json`, never a shared `resume.json` (concurrent sessions would clobber each other) — with `resume_cron_id` already set to the taskId or cron id step 3 returned — or `null` when step 3 was skipped — `resume_kind` (`scheduled_task` | `cron` | `null`) and `resume_retries` at 0, so CANCEL can delete the exact job deterministically even after a context compaction:
   `{ "goal": "<batch goal>", "wake_at_epoch": <n>, "resume_cron_id": "<id from step 3>", "resume_kind": "scheduled_task|cron|null", "resume_retries": 0, "lead_task": "<your own in-progress task, reconciled + full state>" }`
5. **Stop.** Do no further work. The session goes idle until the resume fires — this is what lets the lead itself resume without any OS scheduler. With no resume job it stays idle until the User comes back, which is the right outcome when nothing was waiting on the clock.

## RESUME — run when the scheduled resume fires

1. **Cancelled?** If this session's `resume-<session_id>.json` is absent, the stand-down was cancelled (see CANCEL) — do nothing and stop. The resume fired into a no-op; that is expected.
2. **Re-verify (bounded).** `bash ~/.claude/usage-guard/guard.sh`. If still `breach:true` (the window hasn't actually reset yet), increment `resume_retries` in `resume-<session_id>.json` and re-schedule ~5 min out with the same mechanism as STANDDOWN step 3 (update `resume_cron_id`/`resume_kind`), then stop — **but cap it:** once `resume_retries` reaches 3, do NOT reschedule again. Instead `PushNotification` (proactive) `usage-guard: resume delayed 3× — still breaching well past reset, check guard.sh / the usage cache manually` and stop, so a stuck or false breach can never silently loop forever.
3. **Notify.** `PushNotification`: `usage-guard: limits reset — resuming.`
4. **Clean up.** Delete this session's `resume-<session_id>.json` and `standdown-<session_id>.json` only — never another session's files. Best-effort, also delete the fired scheduled task (`delete_scheduled_task`) if it is still listed.
5. **Continue** the work from where it stood down, using `lead_task` from the deleted checkpoint to pick the thread back up.

## CANCEL — abort a pending stand-down on request

Run when the user asks to cancel the resume / not stand down after all.

1. **Drop the checkpoint.** `bash ~/.claude/usage-guard/cancel.sh <session_id>` — clears this session's `standdown-<session_id>.json` + `resume-<session_id>.json` (the status line pause clears). There is NO mute: the guard stays armed, so if the session is still in breach the next Stop hook stands down again — intended, the guard cannot be silenced. Cancel is only durable once the breach has actually passed.
2. **Drop the resume job**, if there is one. `cancel.sh` prints the checkpoint's `resume_cron_id` before it clears the file — `null` means nothing was scheduled and this step is done. Otherwise, by `resume_kind`: `scheduled_task` -> `delete_scheduled_task({taskId})`, works from any window; `cron` -> `CronDelete` that exact id, no guessing (read it from `resume-<session_id>.json` yourself if you skipped `cancel.sh`); a terminal cron can be deleted **only from the window that created it**, from any other window close that window instead. Either way this is best-effort — with the checkpoint gone, an orphaned job just fires into a no-op (RESUME aborts at step 1).
3. **No re-arm step** — there is no mute to remove; the guard is always armed.

## Anti-patterns

A resume with nothing to resume is waste: the session wakes, says the limits reset, and
idles. Schedule one only when work actually continues.

`/goal` is condition-based; it busy-loops the Stop hook and burns quota every
cycle. For "hold until HH:MM" use a one-shot scheduled task in the desktop app (`create_scheduled_task`; a session cron dies when the app idle-stops the session), `CronCreate` only in the terminal — the
same primitives usage-guard's own resume uses — and stay idle. Also: `/goal clear`
may surface one stale-condition Stop-hook error afterward (Claude Code internal,
harmless).

Never call the usage API directly — `guard.sh` reads the cache `claude-plan-usage-statusline` maintains and, when it is stale, runs that tool's own `statusline.rb --refresh-cache` (once per 15 min, token from `$CLAUDE_CODE_OAUTH_TOKEN`, `~/.agents/keys/claude-oauth-token` or the keychain).

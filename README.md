# usage-guard

**A plan-usage guardrail for [Claude Code](https://code.claude.com/docs).** When
your five-hour headroom runs low, usage-guard stands the **lead session** down,
sends a notification, and schedules an automatic resume one minute after the
limit resets — then wakes and picks the work back up.

Built entirely from Claude Code's own primitives — a **Stop and PostToolUse hook** for detection,
a **skill** for the stand-down / resume protocol, and a one-shot **cron** for the
timed resume. No daemon, no OS scheduler, no background process to babysit.

---

## Why

Long autonomous runs — overnight batches, agent teams — don't fail gracefully at a
rate limit. They stall mid-task, burn the last of a window on a half-finished
edit, or sit idle for hours past a reset that already happened. The disciplined
thing is to **stop early, checkpoint, notify, and resume the moment the window
reopens.** usage-guard encodes that discipline so the run does it on its own.

## How it works

```mermaid
flowchart TD
    P["claude-plan-usage-statusline<br/>statusline.rb"] -. writes cache .-> B
    B -. stale: statusline.rb --refresh-cache .-> P
    A["Stop hook · after every lead response<br/>PostToolUse · after every lead tool call, on breach"] --> B["guard.sh reads<br/>/tmp/claude_usage_cache.json"]
    B --> C{"remaining ≤ stop_at_remaining?<br/>(per window)"}
    C -->|no| E["clear standdown marker"]
    C -->|yes, standdown already running| W["warn only<br/>(latched by the session's resume file)"]
    C -->|yes, new| F["write marker + warn<br/>inject STANDDOWN directive"]

    F --> G["lead runs the usage-guard skill · STANDDOWN"]
    G --> N1["PushNotification"]
    G --> R["checkpoint task + goal<br/>→ resume-&lt;session_id&gt;.json"]
    G --> K["one-shot resume at reset + grace<br/>(desktop scheduled task or CronCreate)"]
    G --> S["lead STOPs — idle until the resume"]

    K -.fires after reset.-> Z["lead runs the usage-guard skill · RESUME"]
    Z --> N2["PushNotification"]
    Z --> CO["continue the work"]
```

Subagents already running are left alone — they finish and return. Only the
lead stands down. New subagents are a different story: a `PreToolUse` gate on
the `Agent` tool refuses to spawn one while the same breach that would stand
the lead down is active, so a dispatch fired moments before the limit doesn't
keep spending from a lead that's already stood down — and can't be killed
mid-task by the limit itself.

| Component | Role |
|-----------|------|
| **`guard.sh`** | Reader of the usage cache. Emits a JSON verdict (remaining, reset, wake time). Never calls the API itself; a missing or stale cache makes it run `statusline.rb --refresh-cache` (2 s cap, at most once per `refresh_min_interval_seconds`) and report the outcome as `refresh`. |
| **`stop-hook.sh`** | On `Stop`, and on `PostToolUse` for lead tool calls once per breach episode so a long turn stands down before the hard limit ends it with no Stop: writes/clears the session-scoped `standdown-<session_id>.json` marker, warns, and — once per standdown — injects the directive that makes the lead run the skill; on an unknown reading with a failed refresh (`http_*`/`backoff`) it blocks once per 15 min per session so the lead checks `get_usage`. |
| **`pretool-hook.sh`** | On `PreToolUse` for the `Agent` tool: re-uses `guard.sh`'s verdict and denies the spawn on breach, with a reason the model won't retry in a loop. A session on a custom model is exempt — its spend never touches the plan. Allows on any other reading, including a failure to read the cache. |
| **`usage-guard` skill** | The `STANDDOWN`, `RESUME`, and `CANCEL` protocols the lead executes: notify, checkpoint, schedule and honor the resume cron, or abort a pending stand-down. |
| **`cancel.sh`** | On-request cancel: clears a session's marker + checkpoint so a pending resume becomes a no-op. There is no mute — the guard stays armed, so cancel is durable only once the breach has passed. Surfaces the checkpoint's `resume_cron_id` so the owning window can `CronDelete` the job precisely. |

## Design notes

Where the correctness lives:

- **Fail-open, never fail-closed.** A missing, malformed, rate-limited, or
  stale cache yields `breach:false` with a `reason` (`no_cache`, `bad_cache`,
  `no_data`, or `stale_cache` when the cache is older than `max_age_seconds`;
  a failed refresh adds `refresh`, e.g. `no_token`, `http_401`, `backoff`),
  and the Stop hook leaves any active pause untouched. The one exception: a
  stale cache is a lower bound (utilization only grows until `resetsAt`), so
  an enabled window in it that already has remaining <= `stop_at_remaining`
  with `resetsAt` still in the future is a real breach, flagged `"stale": true`
  with `age_seconds`. The spawn gate goes
  further: anything that stops it from
  reading a clean verdict — `guard.sh` missing, Ruby absent, unparseable
  output — also means allow. A monitor that halts your work because it
  couldn't read a temp file is worse than no monitor.
- **Fire once per standdown.** The injected directive is latched by the session's
  `resume-<session_id>.json`: the hook drives the skill only when a standdown isn't
  already in progress, so a breach that persists across responses never busy-loops
  the lead.
- **Session-scoped state.** Every marker and roster file is keyed by `session_id`
  (`standdown-<id>.json`, `resume-<id>.json`), so concurrent Claude Code sessions
  never share — or clobber — each other's checkpoint. Only the usage cache and
  `config.json` are global, because they are account-wide by nature.
- **Self-resume without an OS scheduler.** `additionalContext` on the Stop hook
  continues the conversation exactly once, giving the lead a turn to stand down
  and schedule a one-shot resume for the reset. The resume is scheduled on every
  stand-down; RESUME ends silently when nothing is left. In the desktop app that is a
  scheduled task (`create_scheduled_task`, stored on disk) that wakes the session
  by message, because the app stops sessions idle for ~4 h and a session cron
  dies with them; in the terminal, or when the scheduled task is refused, it is a
  one-shot `CronCreate`. The lead then
  goes idle until that single resume fires — no `/loop` to keep alive, nothing
  written into the OS.
- **Deterministic teardown.** `STANDDOWN` records the resume job's id and kind in
  the checkpoint (`resume_cron_id`, `resume_kind`), so cancelling deletes the exact
  job instead of guessing or depending on the id surviving a context compaction.
  A scheduled task can be deleted from any session; the one hard limit is the
  platform's: session-only crons can be removed only from the window
  that created them.
- **One cache producer.** Detection reads the exact cache the status line already
  maintains; a stale cache (a session that draws no status line, such as the
  desktop app) is refreshed through the producer's own `--refresh-cache` mode,
  so usage-guard never duplicates the OAuth call. That mode needs a token:
  `$CLAUDE_CODE_OAUTH_TOKEN`, `~/.agents/keys/claude-oauth-token`, or the
  keychain item; without one the reading stays unknown (`refresh: no_token`).
- **Native or custom model.** On a breach the hook reads the session
  transcript's most recent non-sidechain assistant entry: `/^claude-/i` is
  native, anything else custom, unreadable unknown. A custom model doesn't
  spend the plan quota the guard watches — its requests go to the custom
  provider — so a custom session stands aside entirely: no marker, no pause
  badge, no spawn gate. Native and unknown sessions guard as before, the
  marker records which model stood down, and a native breach message is
  tagged `(claude)`; an unreadable model tags nothing.
- **Deferring costs you.** Ignore the warning and keep prompting past the limit and
  the push applies +5 min to the scheduled resume — but only per genuinely ignored
  warning, at most once per 5 min of real wall-clock time, and never to a
  hook-forced continuation (e.g. a `/goal` busy-loop). You are burning quota that
  delays the real reset, so the estimate moves with it, without a machine-driven
  loop outrunning real time. Frozen once you stand down.
- **The pause badge self-expires.** The status line hides `⏸paused …` once the wake
  time is safely past even if no resume ran, and the hook reaps orphaned markers an
  hour past their wake — a stood-down idle session can't freeze a stale time forever.

## Dependency

usage-guard consumes `/tmp/claude_usage_cache.json`, produced by
[claude-plan-usage-statusline](https://github.com/romacv/claude-plan-usage-statusline) --
written on every render from Claude Code's own stdin data when available, and
by its OAuth API fallback otherwise (`statusline.rb --refresh-cache`, which
guard.sh runs when the cache is stale). If it's installed, usage-guard reuses
it; if not, the installer fetches `statusline.rb`. With the status line installed, a stood-down session
says so live, ahead of everything else on its first line:

```
⏸paused to 20:01 | ◆Opus 5·1M | ▤Ctx:62% | ▮5h:8% ⧖2h11m | ▮1w:46% ⧖Sep 7 11:00
```

The badge appears the moment the stand-down marker is written and clears itself
once the window has reset.

**Requirements:** macOS · Ruby (system Ruby is fine) · Claude Code, authenticated.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/romacv/claude-usage-guard/main/install.sh | sh
```

Restart Claude Code so the hooks, spawn gate, and skill load.

## Use

Nothing to invoke. Run your work as usual. The hook watches headroom after
every response and every tool call; when it crosses the threshold the lead automatically notifies,
stands itself down, checkpoints, and schedules the resume. One minute after the
5h limit resets the cron fires and the lead continues from where it stood down.

In the terminal the session must stay open for the resume cron to fire (it is
session-only, nothing is written to the OS).

## Anti-patterns

Don't use `/goal` to hold a session until a fixed time. `/goal` is
condition-based — it re-evaluates on every Stop-hook fire, so "wait until HH:MM"
busy-loops the hook and burns quota every cycle. For a time-based hold, schedule a
one-shot resume the way usage-guard's own resume does (a desktop scheduled task,
or `CronCreate` in the terminal) and stay idle. Separately: `/goal clear` may surface one stale
"Stop hook error" quoting the just-cleared condition afterward — that is Claude
Code's own `/goal` internals, not usage-guard (its Stop hook always exits 0 and
never reads or quotes goal state), and is harmless.

## Cancel a pending stand-down

Changed your mind mid-pause? Cancel it:

```sh
~/.claude/usage-guard/cancel.sh            # list sessions currently standing down
~/.claude/usage-guard/cancel.sh <id>       # cancel that session
~/.claude/usage-guard/cancel.sh --all      # cancel every standing-down session
```

Cancel clears the session's marker + checkpoint (the status line pause disappears).
Any resume already scheduled becomes a no-op — with the checkpoint gone, the
`RESUME` protocol aborts when the resume fires. There is no mute: the guard stays
armed, so if the session is still below the threshold the next Stop hook stands it
down again. Cancel is durable only once the breach has actually passed.

The resume itself is a desktop scheduled task or, in the terminal, a session-only
cron. `cancel.sh` prints its id (the `STANDDOWN` protocol records it in the
checkpoint as `resume_cron_id`, its kind as `resume_kind`) so you can delete it
precisely: a scheduled task with `delete_scheduled_task` from any session, a
session-only cron with `CronDelete` only from the window that scheduled it. If
you'd rather not bother, leave it: with the checkpoint gone it just fires into a
no-op.

## Configure

`~/.claude/usage-guard/config.json`:

| Key | Default | Meaning |
|-----|---------|---------|
| `stop_at_remaining` | `{"5h": 13, "7d": 7}` | Stand down when a window's remaining headroom (%) falls to its value or below; a number sets both. |
| `resume_grace_seconds` | `60` | Resume this many seconds after the reset. |
| `windows` | `["5h", "7d"]` | Which limit windows to watch. |
| `max_age_seconds` | `300` | Reject the cache as `stale_cache` once it's older than this, unless a window in it already breached and has not reset (then a breach with `"stale": true`). |
| `refresh_min_interval_seconds` | `300` | Minimum gap between `--refresh-cache` attempts, across all sessions. |

Per-run overrides: `USAGE_GUARD_STOP_AT=80`, `USAGE_GUARD_MAX_AGE=3600`.

**Trying it out.** Force a breach on demand by raising the threshold above your
current remaining:

```sh
USAGE_GUARD_STOP_AT=90 ~/.claude/usage-guard/guard.sh   # inspect the verdict
```

For production, keep tight limits (e.g. `{"5h": 13, "7d": 7}`).

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/romacv/claude-usage-guard/main/uninstall.sh | sh
```

Removes usage-guard, its skill, its hooks, and its spawn gate; leaves the
shared cache producer in place.

## License

MIT © Roman Resenchuk

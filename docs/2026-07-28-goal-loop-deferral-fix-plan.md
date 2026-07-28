# Plan: /goal-loop deferral runaway + stale-goal Stop-hook error

Incident (2026-07-28, cloudshot session): a `/goal` Stop-hook loop re-fired dozens
of times over ~15 min while the agent held for a wall-clock time; usage-guard's
resume time crept 17:01 → 18:25. `/goal clear` then surfaced a "Stop hook error"
quoting the stale goal condition.

## Root cause 1 — CONFIRMED in usage-guard: deferral push counts every Stop fire

`stop-hook.sh`, lead pre-stand-down branch (repo lines 121–132; same logic in the
installed copy `~/.claude/usage-guard/stop-hook.sh`):

```ruby
deferrals = prev["deferrals"].to_i + (File.exist?(marker) ? 1 : 0)
pushed = base + deferrals * 300
```

- The +5 min "deferral penalty" increments on **every** Stop-hook firing while in
  breach and not yet stood down. It reads `stop_hook_active` (`STOP_ACTIVE`) but
  uses it only to gate the injected directive — **not** the deferral increment.
- A `/goal` loop forces a Stop → continue → Stop cycle with near-zero work per
  cycle. Dozens of fires in ~15 real minutes each added 300 s.
- Smoking gun, today's live marker
  `~/.claude/usage-guard/standdown-0b12330a-….json`:
  `"deferrals":17, "base_wake_at_epoch":1785229259 (17:00:59),
  "wake_at_epoch":1785234359 (18:25:59)` — 17 × 300 s = 85 min of push for ~15 min
  of "Holding" replies.
- The penalty is a fixed per-fire heuristic, not measured consumption. `guard.sh`
  already re-reads the API's `resetsAt` fresh on every fire, so the *real* reset
  time is always in `base_wake_at_epoch`; the stacked +300 s/fire double-counts and,
  under a machine-driven loop, runs 5–6× faster than real time. Each "Holding" turn
  does cost some tokens, but the push is unrelated to that cost — verdict: bug in
  usage-guard, not correct behavior.

## Root cause 2 — NOT usage-guard: stale-goal "Stop hook error" on /goal clear

- usage-guard's Stop hook always `exit 0`, emits only
  `systemMessage`/`additionalContext`, and never reads or quotes goal state. The
  error text (stale PR statuses) can only originate from the `/goal` feature's own
  internal Stop-hook evaluation running once more against just-cleared state.
- The other two configured Stop hooks (`refresh-usage-cache.sh` — detached, silent;
  `enforce-no-trailing-offer.sh` — response-text only) also never touch goal state.
  "Ran 6 stop hooks" includes plugin/internal hooks outside this repo.
- **Flag:** this depends on Claude Code's closed `/goal` internals and cannot be
  confirmed or patched from usage-guard's side. Fix is procedural/documentation
  (see Phase 3) + optional upstream report to Anthropic.

## Blocker to a clean release — repo/live drift (bidirectional)

- Installed `stop-hook.sh` (2026-07-27) and `SKILL.md` are the **lead-only**
  variant (Agent Teams removed system-wide 2026-07-27) — never committed here.
- Repo HEAD (= tag `v1.3.1`) still carries the teammate machinery, and separately
  has the window-label reporting (`5h/7d/5h+7d`) that the live copy lacks; live
  `guard.sh` predates repo HEAD (old `["5h","7d"]` windows default).
- Releasing the deferral fix on either base alone ships an incoherent repo.
  Reconcile first (Phase 1).

## Fix

### Phase 1 — reconcile repo to live intent (own commit)
Port the installed lead-only variant into the repo as the new baseline:
- `stop-hook.sh`: drop `IS_TEAMMATE` ancestry walk + teammate branch/directive;
  **keep** repo's window-label reporting (`label`, `brem`) — re-apply it to the
  lead-only shape (live copy hardcodes "5h headroom", repo's labeling is correct).
- `skill/SKILL.md`: adopt the installed lead-only text (no teammate
  pause/rehydrate steps).
- `README.md`: remove Agent Teams stand-down/teammate content (mermaid, "Pause,
  don't kill", teammate self-standdown bullets); lead-only story.
- `guard.sh`: repo version wins (`["5h"]` default, matches live config).

### Phase 2 — deferral fix in `stop-hook.sh` (the bug fix, own commit)
In the pre-stand-down branch, increment only on a *genuine* deferral:

```ruby
can_defer = File.exist?(marker) && !stop_active &&
            (now - prev["last_deferral_epoch"].to_i >= 300)
deferrals = prev["deferrals"].to_i + (can_defer ? 1 : 0)
v["last_deferral_epoch"] = can_defer ? now : prev["last_deferral_epoch"].to_i
```

- `!stop_active`: a turn continued by a Stop hook (`stop_hook_active:true` — the
  `/goal` loop, or any hook continuation) is a forced re-entry, not the user
  ignoring the warning. (Relies on Claude Code setting the flag on goal-driven
  continuations — believed true but not provable from here; hence the next guard.)
- Wall-clock rate limit (one increment per 300 s): even if a loop fires with
  `stop_hook_active:false`, the push can never outrun real time (worst case 1:1,
  vs today's ~5.7:1). `now` already exists at the reaper (repo line 74).
- Freeze-on-standdown behavior (resume.json branch) unchanged.
- Simpler alternative, needs lead/User decision: delete the deferral push
  entirely and trust `guard.sh`'s fresh `resetsAt` (base already tracks the real
  reset). Recommended default: keep the heuristic, gated as above — it preserves
  the documented "deferring costs you" behavior for real user prompts.
- Update README "Deferring costs you" bullet: push applies per ignored warning at
  most once per 5 min of real time, never to hook-forced continuations.

### Phase 3 — documentation rule: time-based holds are cron's job, not /goal's
- README (new "Anti-patterns" note) + `skill/SKILL.md` short section:
  "`/goal` is condition-based; it busy-loops the Stop hook and burns quota every
  cycle. For 'hold until HH:MM' use a one-shot session cron (`CronCreate`) — the
  same primitive usage-guard's own resume uses — and stay idle. Also: `/goal clear`
  may surface one stale-condition Stop-hook error afterward (Claude Code internal,
  harmless)."
- Keep this in usage-guard's own docs/skill (Claude-only surface), NOT in the
  shared `~/.agents/rules/` tree — canon forbids runtime-specific mechanics there.

### Phase 4 — release (repo pattern: commit to main, annotated tag, push)
- Commits: (1) lead-only reconcile, (2) deferral fix, (3) docs. Tag `v1.4.0`
  (behavior change ⇒ minor bump; pattern per existing `v1.x.y` tags).
- Push `main` + tag to `origin` (`github.com/romacv/claude-usage-guard`) —
  **needs the User's explicit go-ahead** per canon before any push.

### Phase 5 — reinstall / re-sync live copies
- `cp` repo `guard.sh`, `stop-hook.sh`, `cancel.sh` → `~/.claude/usage-guard/`
  and `skill/SKILL.md` → `~/.claude/skills/usage-guard/SKILL.md` (or re-run
  `install.sh` after the push — it curls from `main`).
- `~/.claude/settings.json` Stop-hook entry is path-based and unchanged — no
  re-wire; command hooks re-read the script per fire, no Claude Code restart
  needed. `config.json` is preserved by design.
- Stale marker from today is reaped automatically (wake + 1 h) by any live
  session's hook; may also delete
  `~/.claude/usage-guard/standdown-0b12330a-….json` manually.

## Verification
1. `USAGE_GUARD_STOP_AT=90 ~/.claude/usage-guard/guard.sh` — forced breach verdict.
2. Simulate fires: pipe `{"session_id":"t1","stop_hook_active":true}` (and `false`)
   into `stop-hook.sh` repeatedly with `USAGE_GUARD_STOP_AT=90`; assert marker
   `deferrals` stays 0 on `stop_active` fires, rises at most once per 300 s
   otherwise, and freezes once a fake `resume-t1.json` exists.
3. Shell lint: `bash -n stop-hook.sh guard.sh`; then clean up test markers.

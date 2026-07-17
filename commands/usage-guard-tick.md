---
description: usage-guard tick — check plan-usage headroom, stand down (and, if lead, pause the Agent Teams roster) when low, then self-reschedule the next tick to reset+grace.
---

One tick of the usage-guard loop. Run this on a recurring `/loop` (dynamic pacing):

    /loop /usage-guard-tick <optional description of the work to continue>

The optional argument is your WORK GOAL — what to continue doing while there is
headroom. Passed through as: $ARGUMENTS

## Do exactly this, in order

1. Run the detector and parse its JSON verdict:

       bash ~/.claude/usage-guard/guard.sh

2. **If `breach` is false** (headroom OK):
   - If `~/.claude/usage-guard/resume.json` exists, you are resuming after a
     standdown: restore the paused roster — for each teammate recorded there,
     re-send its pending task via SendMessage (or re-spawn it if its pane died),
     resume the batch from the task ledger, then delete resume.json.
   - Otherwise continue the work goal: $ARGUMENTS
   - Choose your next-tick delay = `heartbeat_seconds` from
     `~/.claude/usage-guard/config.json` (default 1200s), unless teammate reports
     or the harness will re-invoke you sooner. Schedule the next tick with that
     delay, re-firing this same `/loop /usage-guard-tick` prompt.

3. **If `breach` is true** (headroom `remaining <= stop_at_remaining` on an
   enabled window): **STAND DOWN. Do not start or continue any product work.**
   - If you are an Agent Teams lead: `TaskStop` every active teammate. Before
     stopping them, capture enough to rebuild the batch — write the roster
     (each teammate's role/slug + its in-flight task), the full task ledger, and
     the work goal "$ARGUMENTS" to `~/.claude/usage-guard/resume.json`. Reconcile
     the ledger first: no task may be left `in_progress` after its owner stops.
   - Schedule the next tick for reset+grace using `seconds_until_wake` from the
     verdict. `ScheduleWakeup` clamps a delay to at most 3600s, so if
     `seconds_until_wake` > 3600, schedule 3600 and hop again on the next tick;
     keep hopping (doing no work) until `now >= wake_at_epoch` and the guard
     clears. Re-fire this same `/loop /usage-guard-tick` prompt each time.
   - Report ONE line: standing down until `wake_at_iso` — window, remaining 5h/7d.

Never call the usage API yourself; `guard.sh` only reads the cache that
claude-plan-usage-statusline keeps fresh.

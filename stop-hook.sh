#!/usr/bin/env bash
# usage-guard Stop hook.
#
# Runs after each Claude Code response. Reads the usage verdict and:
#   - on breach: writes the standdown marker + shows a one-line warning;
#   - AND, only when a /loop is active for this session, injects a standdown
#     directive as additionalContext so the running loop pauses itself and
#     ScheduleWakeups to reset+grace — no separate command, no OS scheduler.
#
# Why gate on an active loop: additionalContext on a Stop hook continues the
# conversation. Inside a /loop that is the tick we want (the model schedules the
# wake and then sleeps). In a plain session it would force an unwanted extra
# turn with no ScheduleWakeup to escape to, so there we only warn.
#
# The marker is cleared only on a DEFINITE no-breach (a real cache reading),
# never on an unknown reading (no_cache/bad_cache/no_data) — a transient cache
# miss must not cancel an active pause. Never blocks the stop.
set -uo pipefail

DIR="$HOME/.claude/usage-guard"
INPUT="$(cat 2>/dev/null)"
VERDICT="$("$DIR/guard.sh" 2>/dev/null)"
[ -z "$VERDICT" ] && exit 0

SESSION_ID="$(printf '%s' "$INPUT" | ruby -rjson -e 'puts((JSON.parse(STDIN.read)["session_id"] rescue "").to_s)' 2>/dev/null)"

VERDICT="$VERDICT" SESSION_ID="$SESSION_ID" ruby -rjson <<'RUBY'
v = (JSON.parse(ENV["VERDICT"]) rescue {})
dir = File.expand_path("~/.claude/usage-guard")
marker = File.join(dir, "standdown.json")

unless v["breach"]
  # reason present (no_cache/bad_cache/no_data) == unknown: leave any pause alone.
  File.delete(marker) if v["reason"].nil? && File.exist?(marker)
  exit 0
end

# Human-readable cause, shown by the status line ("paused by <by>"). Generic on
# purpose: any other scheduler may write this marker with its own `by`.
v["by"] = "#{v["window"]} limit"
File.write(marker, JSON.generate(v))

pct = ->(x) { x.nil? ? "?" : x.round }
clock = lambda do |epoch|
  return v["wake_at_iso"].to_s if epoch.nil?
  t = Time.at(epoch.to_i)
  t.strftime("%Y%m%d") == Time.now.strftime("%Y%m%d") ? t.strftime("%H:%M") : t.strftime("%b %-d %H:%M")
end
resume_at = clock.(v["wake_at_epoch"])

out = {
  "systemMessage" => "usage-guard: 5h headroom #{pct.(v["remaining_5h"])}% <= #{pct.(v["stop_at_remaining"])}% limit -- paused, resume #{resume_at}."
}

sid = ENV["SESSION_ID"].to_s
loop_active =
  if sid.empty?
    false
  else
    path = File.expand_path("~/.claude/loops/#{sid}.json")
    File.exist?(path) && (JSON.parse(File.read(path))["active"] rescue false)
  end

if loop_active
  secs = v["seconds_until_wake"].to_i
  out["hookSpecificOutput"] = {
    "hookEventName" => "Stop",
    "additionalContext" =>
      "usage-guard STANDDOWN. 5h headroom #{pct.(v["remaining_5h"])}% <= #{pct.(v["stop_at_remaining"])}% limit. " \
      "Do NOT start or continue any product work now. " \
      "If you are an Agent Teams lead: TaskStop every active teammate and write the roster + task ledger + goal to " \
      "~/.claude/usage-guard/resume.json (reconcile first — no task left in_progress). " \
      "Then call ScheduleWakeup with delay #{secs}s (the tool clamps to <=3600s; if larger it will re-check and hop " \
      "again next tick) to resume ~1 minute after the 5h limit resets at #{resume_at}. " \
      "Reply one line: paused, resume #{resume_at}. " \
      "Once a later tick no longer carries this standdown context and headroom is back, restore from resume.json and continue."
  }
end

puts JSON.generate(out)
RUBY
exit 0

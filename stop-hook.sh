#!/usr/bin/env bash
# usage-guard Stop hook.
#
# Runs after each lead response. Reads the usage verdict and:
#   - no breach (real reading): clears any stale standdown marker;
#   - breach, standdown NOT yet in progress (no resume.json): writes the marker,
#     warns, and injects a directive telling the lead to run the usage-guard
#     skill STANDDOWN protocol (notify + stop all teammates + checkpoint +
#     schedule the resume cron). additionalContext on a Stop hook continues the
#     conversation once, so the lead gets exactly one turn to execute it, then
#     stops and stays idle until the resume cron fires — no /loop, no OS
#     scheduler needed;
#   - breach, standdown already in progress (resume.json exists): warns only, so
#     the injected directive fires once per standdown, never in a busy loop.
#
# The marker is cleared only on a DEFINITE no-breach; an unknown reading
# (no_cache/bad_cache/no_data) leaves any active pause untouched. Never blocks.
set -uo pipefail

DIR="$HOME/.claude/usage-guard"
INPUT="$(cat 2>/dev/null)"
VERDICT="$("$DIR/guard.sh" 2>/dev/null)"
[ -z "$VERDICT" ] && exit 0

SESSION_ID="$(printf '%s' "$INPUT" | ruby -rjson -e 'puts((JSON.parse(STDIN.read)["session_id"] rescue "").to_s)' 2>/dev/null)"

# Per-session mute: `off-<session_id>` silences usage-guard for one session only
# (config is global, so this is how you exempt a single window without disarming
# the others). Present → do nothing this session.
SID_SAFE="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9_-')"
[ -n "$SID_SAFE" ] && [ -f "$DIR/off-$SID_SAFE" ] && exit 0

VERDICT="$VERDICT" SESSION_ID="$SESSION_ID" ruby -rjson <<'RUBY'
v = (JSON.parse(ENV["VERDICT"]) rescue {})
dir = File.expand_path("~/.claude/usage-guard")

# Session-scope the state so concurrent Claude Code sessions never share one
# marker/roster. session_id keys the files exactly like the loop-status segment;
# the usage cache and config stay global (account-wide by nature).
sid = ENV["SESSION_ID"].to_s.gsub(/[^A-Za-z0-9_-]/, "")
suffix = sid.empty? ? "" : "-#{sid}"
marker = File.join(dir, "standdown#{suffix}.json")
resume = File.join(dir, "resume#{suffix}.json")

unless v["breach"]
  File.delete(marker) if v["reason"].nil? && File.exist?(marker)
  exit 0
end

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

# Fire the standdown directive once per standdown: only when a standdown is not
# already in progress. resume.json is written by the STANDDOWN protocol and
# removed by RESUME, so it is the latch.
unless File.exist?(resume)
  out["hookSpecificOutput"] = {
    "hookEventName" => "Stop",
    "additionalContext" =>
      "usage-guard BREACH: 5h headroom #{pct.(v["remaining_5h"])}% <= #{pct.(v["stop_at_remaining"])}% limit. " \
      "Invoke the usage-guard skill and run its STANDDOWN protocol NOW: PushNotification, then stop the lead and " \
      "every Agent Teams teammate (SendMessage each, then TaskStop), checkpoint THIS session's roster + goal to " \
      "#{resume} (session-scoped — use exactly this path, never a shared one), and CronCreate a one-shot resume for " \
      "~1 min after the reset at #{resume_at} whose prompt runs the usage-guard RESUME protocol reading #{resume} and " \
      "deleting #{resume} + #{marker} on completion. Let running subagents finish; do not touch them. " \
      "Then STOP and stay idle until the cron fires. Reply one line: paused, resume #{resume_at}."
  }
end

puts JSON.generate(out)
RUBY
exit 0

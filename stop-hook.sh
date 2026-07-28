#!/usr/bin/env bash
# usage-guard Stop hook.
#
# Runs after each lead response. Reads the usage verdict and:
#   - no breach (real reading): clears any stale standdown marker;
#   - breach, standdown NOT yet in progress (no resume.json): writes the marker,
#     warns, and injects a directive telling the lead to run the usage-guard
#     skill STANDDOWN protocol (notify + checkpoint + schedule the resume cron).
#     additionalContext on a Stop hook continues the conversation once, so the
#     lead gets exactly one turn to execute it, then stops and stays idle until
#     the resume cron fires — no /loop, no OS scheduler needed;
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
STOP_ACTIVE="$(printf '%s' "$INPUT" | ruby -rjson -e 'puts(((JSON.parse(STDIN.read)["stop_hook_active"] rescue false) == true) ? "1" : "0")' 2>/dev/null)"

VERDICT="$VERDICT" SESSION_ID="$SESSION_ID" STOP_ACTIVE="$STOP_ACTIVE" ruby -rjson <<'RUBY'
v = (JSON.parse(ENV["VERDICT"]) rescue {})
dir = File.expand_path("~/.claude/usage-guard")
stop_active = ENV["STOP_ACTIVE"] == "1"

# Session-scope the state so concurrent Claude Code sessions never share one
# marker/roster. session_id keys the files exactly like the loop-status segment;
# the usage cache and config stay global (account-wide by nature).
sid = ENV["SESSION_ID"].to_s.gsub(/[^A-Za-z0-9_-]/, "")
suffix = sid.empty? ? "" : "-#{sid}"
marker = File.join(dir, "standdown#{suffix}.json")
resume = File.join(dir, "resume#{suffix}.json")

# Global reaper for orphaned markers. A stand-down marker/checkpoint belongs to
# a session that may never respond again (it stood down and went idle), so no
# per-session cleanup can reach it — some other live session's hook must sweep.
# A legitimately pending marker always has a FUTURE wake_at_epoch; one more than
# an hour past is provably dead. Skip files with no parseable epoch, never guess.
now = Time.now.to_i
Dir.glob(File.join(dir, "{standdown,resume}-*.json")).each do |f|
  begin
    m = JSON.parse(File.read(f))
    w = m.is_a?(Hash) ? m["wake_at_epoch"].to_i : 0
    File.delete(f) if w > 0 && w + 3600 < now
  rescue Errno::ENOENT
    # a concurrent hook already removed it — fine
  rescue StandardError
    # unparseable/garbage epoch — leave it rather than guess
  end
end

unless v["breach"]
  File.delete(marker) if v["reason"].nil? && File.exist?(marker)
  exit 0
end

v["by"] = "#{v["window"]} limit"

# Deferral penalty: each time this breach warning RE-fires because the user kept
# prompting instead of standing down, push the resume +5 min. Continuing past the
# limit burns more quota and genuinely delays the reset, so the SCHEDULED resume
# must move with it, not just the badge. First warning (no marker yet) shows the
# true wake; each genuine deferral adds 300s on top of guard.sh's current wake.
# A genuine deferral excludes a hook-forced re-entry (stop_hook_active:true — e.g.
# a /goal busy-loop) and is rate-limited to once per 300s of real wall-clock time,
# so a machine-driven loop can never push the resume faster than real time elapses
# (worst case 1:1). The lead reads the pushed time from this marker + the injected
# directive, so the cron moves too. Once a stand-down is active (resume latch
# present) the accumulated push is FROZEN — the marker is the lead's committed
# checkpoint reference, so we neither increment nor rewrite it (a stray
# post-standdown fire must not reset it back to base).
prev = File.exist?(marker) ? (JSON.parse(File.read(marker)) rescue {}) : {}
if File.exist?(resume)
  # Stand-down active: freeze the pushed wake, don't rewrite (the marker is
  # the committed checkpoint reference; a stray fire must not reset it).
  v["deferrals"] = prev["deferrals"].to_i
  %w[base_wake_at_epoch wake_at_epoch wake_at_iso].each { |k| v[k] = prev[k] if prev[k] }
else
  # Pre-stand-down: deferral push (+5 min per genuine ignored breach warning).
  can_defer = File.exist?(marker) && !stop_active &&
              (now - prev["last_deferral_epoch"].to_i >= 300)
  deferrals = prev["deferrals"].to_i + (can_defer ? 1 : 0)
  base = v["wake_at_epoch"].to_i
  if base.positive?
    pushed = base + deferrals * 300
    v["base_wake_at_epoch"] = base
    v["wake_at_epoch"] = pushed
    v["wake_at_iso"] = Time.at(pushed).localtime.strftime("%Y-%m-%dT%H:%M:%S%:z")
  end
  v["deferrals"] = deferrals
  v["last_deferral_epoch"] = can_defer ? now : prev["last_deferral_epoch"].to_i
  File.write(marker, JSON.generate(v))
end

pct = ->(x) { x.nil? ? "?" : x.round }
clock = lambda do |epoch|
  return v["wake_at_iso"].to_s if epoch.nil?
  t = Time.at(epoch.to_i)
  t.strftime("%Y%m%d") == Time.now.strftime("%Y%m%d") ? t.strftime("%H:%M") : t.strftime("%b %-d %H:%M")
end
resume_at = clock.(v["wake_at_epoch"])

# Report the window that actually breached, not a hardcoded "5h". guard.sh emits
# window as "5h", "7d", or "5h+7d"; show that label and the remaining headroom of
# the tightest breached window, so a weekly-cap stand-down never reads as a 5h one.
win = v["window"].to_s
label = win.empty? ? "usage" : win
breached_rems = []
breached_rems << v["remaining_5h"] if win.include?("5h")
breached_rems << v["remaining_7d"] if win.include?("7d")
brem = breached_rems.compact.min

out = {
  "systemMessage" => "usage-guard: #{label} headroom #{pct.(brem)}% <= #{pct.(v["stop_at_remaining"])}% limit -- paused, resume #{resume_at}."
}

# Inject exactly one directive per breach episode, latched so it never busy-loops.
# resume.json is the latch (written by STANDDOWN, removed by RESUME); stop_active
# brakes self-amplification on a hook-continued turn.
unless File.exist?(resume) || stop_active
  out["hookSpecificOutput"] = {
    "hookEventName" => "Stop",
    "additionalContext" =>
      "usage-guard BREACH: #{label} headroom #{pct.(brem)}% <= #{pct.(v["stop_at_remaining"])}% limit. " \
      "Invoke the usage-guard skill and run its STANDDOWN protocol NOW: PushNotification, then checkpoint THIS " \
      "session's in-progress task + goal to #{resume} (session-scoped — use exactly this path, never a shared one), " \
      "and CronCreate a one-shot resume for ~1 min after the reset at #{resume_at} whose prompt runs the usage-guard " \
      "RESUME protocol reading #{resume} and deleting #{resume} + #{marker} on completion. Let running subagents " \
      "finish; do not touch them. Then STOP and stay idle until the cron fires. Reply one line: paused, resume #{resume_at}."
  }
end

puts JSON.generate(out)
RUBY
exit 0

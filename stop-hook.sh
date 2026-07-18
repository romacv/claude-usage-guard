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
#     the injected directive fires once per standdown, never in a busy loop;
#   - breach in a TEAMMATE session (a claude ancestor carries --agent-id): injects
#     the lighter TEAMMATE directive instead (pause self, one SendMessage to the
#     lead, idle — never the lead's PushNotification/CronCreate/checkpoint), latched
#     on the marker's teammate_notified flag so it fires once, not every turn end.
#
# The marker is cleared only on a DEFINITE no-breach; an unknown reading
# (no_cache/bad_cache/no_data) leaves any active pause untouched. Never blocks.
set -uo pipefail

DIR="$HOME/.claude/usage-guard"
INPUT="$(cat 2>/dev/null)"
VERDICT="$("$DIR/guard.sh" 2>/dev/null)"
[ -z "$VERDICT" ] && exit 0

SESSION_ID="$(printf '%s' "$INPUT" | ruby -rjson -e 'puts((JSON.parse(STDIN.read)["session_id"] rescue "").to_s)' 2>/dev/null)"

# Teammate detection. An Agent-Teams teammate CLI is launched with
# `--agent-id <name>@session-<sid>` in its argv; a lead is not. The Stop-hook stdin
# carries no agent/team fields and the environment can't tell them apart, so the
# hook walks up its own process ancestry and looks for a claude process carrying
# --agent-id.
#
# Do NOT use CLAUDE_CODE_CHILD_SESSION for this: it is 1 for a teammate CLI *and*
# for any bridge / remote-controlled lead (the child of a claude.ai bridge session).
# A remote-controlled lead — the normal setup here — was therefore misdetected as a
# teammate, took the teammate branch, and never ran the real STANDDOWN (no
# checkpoint, no resume cron → nothing resumed). argv --agent-id is true for
# teammates ONLY; with no ancestor carrying it we fall back to the lead path.
# stop_hook_active still guards self-amplification on a hook-continued turn.
IS_TEAMMATE=0
_pid="$PPID"
for _ in 1 2 3 4 5 6; do
  { [ -n "$_pid" ] && [ "$_pid" -gt 1 ]; } 2>/dev/null || break
  case "$(ps -o command= -p "$_pid" 2>/dev/null)" in
    *--agent-id*) IS_TEAMMATE=1; break ;;
  esac
  _pid="$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')"
done
STOP_ACTIVE="$(printf '%s' "$INPUT" | ruby -rjson -e 'puts(((JSON.parse(STDIN.read)["stop_hook_active"] rescue false) == true) ? "1" : "0")' 2>/dev/null)"

VERDICT="$VERDICT" SESSION_ID="$SESSION_ID" IS_TEAMMATE="$IS_TEAMMATE" STOP_ACTIVE="$STOP_ACTIVE" ruby -rjson <<'RUBY'
v = (JSON.parse(ENV["VERDICT"]) rescue {})
dir = File.expand_path("~/.claude/usage-guard")
is_teammate = ENV["IS_TEAMMATE"] == "1"
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
# true wake; each deferral adds 300s on top of guard.sh's current wake. The lead
# reads the pushed time from this marker + the injected directive, so the cron
# moves too. Once a stand-down is active (resume latch present) the accumulated
# push is FROZEN — the marker is the lead's committed checkpoint reference, so we
# neither increment nor rewrite it (a stray post-standdown fire must not reset it
# back to base).
prev = File.exist?(marker) ? (JSON.parse(File.read(marker)) rescue {}) : {}
notify_teammate = false
if File.exist?(resume)
  # Lead stand-down active: freeze the pushed wake, don't rewrite (the marker is
  # the lead's committed checkpoint reference; a stray fire must not reset it).
  v["deferrals"] = prev["deferrals"].to_i
  %w[base_wake_at_epoch wake_at_epoch wake_at_iso].each { |k| v[k] = prev[k] if prev[k] }
elsif is_teammate
  # Teammate self-stand-down: NO deferral push (a teammate isn't deferring, it
  # just pauses; its resume is the lead's cron). Latch the one-time notify on the
  # marker's teammate_notified flag — NOT resume.json, which a teammate never
  # writes, so reusing it would re-inject the directive every turn end = a
  # stand-down busy-loop burning quota. stop_active is the extra guard.
  notify_teammate = !(prev["teammate_notified"] == true) && !stop_active
  v["deferrals"] = 0
  v["teammate_notified"] = (prev["teammate_notified"] == true) || notify_teammate
  File.write(marker, JSON.generate(v))
else
  # Lead, pre-stand-down: deferral push (+5 min per ignored breach warning).
  deferrals = prev["deferrals"].to_i + (File.exist?(marker) ? 1 : 0)
  base = v["wake_at_epoch"].to_i
  if base.positive?
    pushed = base + deferrals * 300
    v["base_wake_at_epoch"] = base
    v["wake_at_epoch"] = pushed
    v["wake_at_iso"] = Time.at(pushed).localtime.strftime("%Y-%m-%dT%H:%M:%S%:z")
  end
  v["deferrals"] = deferrals
  File.write(marker, JSON.generate(v))
end

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

# Inject exactly one directive per breach episode, latched so it never busy-loops.
# Teammate path: the teammate pauses ITSELF and reports up — never the lead
# machinery. Lead path: run the full STANDDOWN. resume.json is the lead latch
# (written by STANDDOWN, removed by RESUME); teammate_notified is the teammate
# latch; stop_active brakes self-amplification on a hook-continued turn.
if is_teammate
  if notify_teammate
    out["hookSpecificOutput"] = {
      "hookEventName" => "Stop",
      "additionalContext" =>
        "usage-guard BREACH (teammate): 5h headroom #{pct.(v["remaining_5h"])}% <= #{pct.(v["stop_at_remaining"])}% limit. " \
        "You are a spawned teammate — do the TEAMMATE stand-down, NOT the lead protocol: finish this turn, take no new " \
        "work, and do NOT self-TaskStop (keep your pane alive so the lead resumes you from this transcript). Send ONE " \
        "SendMessage to the lead: 'paused — approaching quota limit; idle, holding state, awaiting your resume.' Then " \
        "go idle and wait. Do NOT PushNotification, CronCreate, or write a checkpoint — those are the lead's alone."
    }
  end
elsif !File.exist?(resume) && !stop_active
  out["hookSpecificOutput"] = {
    "hookEventName" => "Stop",
    "additionalContext" =>
      "usage-guard BREACH: 5h headroom #{pct.(v["remaining_5h"])}% <= #{pct.(v["stop_at_remaining"])}% limit. " \
      "Invoke the usage-guard skill and run its STANDDOWN protocol NOW: PushNotification, then PAUSE the team WITHOUT " \
      "killing it — SendMessage each Agent Teams teammate to finish its turn, save state, and go idle, and LEAVE ITS " \
      "PANE ALIVE. Do NOT TaskStop teammates: a live pane resumes from its own transcript on RESUME; TaskStop only a " \
      "pane that is already dead/unresponsive. Then checkpoint THIS session's roster + goal to " \
      "#{resume} (session-scoped — use exactly this path, never a shared one), and CronCreate a one-shot resume for " \
      "~1 min after the reset at #{resume_at} whose prompt runs the usage-guard RESUME protocol reading #{resume} and " \
      "deleting #{resume} + #{marker} on completion. Let running subagents finish; do not touch them. " \
      "Then STOP and stay idle until the cron fires. Reply one line: paused, resume #{resume_at}."
  }
end

puts JSON.generate(out)
RUBY
exit 0

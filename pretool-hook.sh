#!/usr/bin/env bash
# usage-guard spawn gate. PreToolUse hook, matcher "Agent".
#
# The Stop hook stands the lead down on breach, but does nothing about new
# subagents — a lead can dispatch a batch moments before breaching, stand
# down, and those subagents keep burning the same quota unsupervised, with no
# guarantee they exit cleanly if the limit hits mid-run. This hook closes that
# gap: refuse to spawn a NEW subagent while the same condition that would
# stand the lead down is active. Running subagents are never touched — only
# the Agent tool call itself is gated, before the spawn happens.
#
# Reuses guard.sh for the verdict (same cache, same threshold, no second
# reader of usage data). Fails OPEN: guard.sh missing/unreadable, its output
# unparseable, or Ruby absent all mean "allow" — this gate can delay work, it
# must never be the reason a spawn silently can't happen.
set -uo pipefail

DIR="$HOME/.claude/usage-guard"
cat >/dev/null 2>&1 # drain stdin (tool_input isn't needed for the verdict)

VERDICT="$("$DIR/guard.sh" 2>/dev/null)"
[ -z "$VERDICT" ] && exit 0 # guard.sh missing or produced nothing: allow

VERDICT="$VERDICT" ruby -rjson -e '
v = (JSON.parse(ENV["VERDICT"]) rescue nil)
exit 0 unless v.is_a?(Hash) # unparseable verdict: allow

unless v["breach"]
  exit 0 # below threshold or unknown reading: allow, same as the Stop hook
end

pct = ->(x) { x.nil? ? "?" : x.round }
win = v["window"].to_s
label = win.empty? ? "usage" : win
breached_rems = []
breached_rems << v["remaining_5h"] if win.include?("5h")
breached_rems << v["remaining_7d"] if win.include?("7d")
brem = breached_rems.compact.min

wake_at = v["wake_at_iso"] || "unknown"

reason = "usage-guard: #{label} headroom #{pct.(brem)}% <= #{pct.(v["stop_at_remaining"])}% limit -- " \
  "the lead is standing down (or about to), so no new subagents. Resets ~#{wake_at}. " \
  "Do not retry this spawn now; wait for the resume and dispatch it then."

puts JSON.generate({
  "hookSpecificOutput" => {
    "hookEventName" => "PreToolUse",
    "permissionDecision" => "deny",
    "permissionDecisionReason" => reason
  }
})
' 2>/dev/null
exit 0

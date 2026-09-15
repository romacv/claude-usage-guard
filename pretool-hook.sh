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
# reader of usage data). The session transcript also names the model serving
# it (/^claude-/i native, anything else custom): a custom-model session
# doesn't spend the plan quota the gate protects, so its spawns are allowed.
# Fails OPEN: guard.sh missing/unreadable, its output unparseable, or Ruby
# absent all mean "allow" — this gate can delay work, it must never be the
# reason a spawn silently can't happen. An unreadable model keeps the
# fail-safe deny.
set -uo pipefail

DIR="$HOME/.claude/usage-guard"
INPUT="$(cat 2>/dev/null)" # tool_input isn't needed; transcript_path is
TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | ruby -rjson -e 'puts((JSON.parse(STDIN.read)["transcript_path"] rescue "").to_s)' 2>/dev/null)"

VERDICT="$("$DIR/guard.sh" 2>/dev/null)"
[ -z "$VERDICT" ] && exit 0 # guard.sh missing or produced nothing: allow

VERDICT="$VERDICT" TRANSCRIPT_PATH="$TRANSCRIPT_PATH" ruby -rjson -e '
v = (JSON.parse(ENV["VERDICT"]) rescue nil)
exit 0 unless v.is_a?(Hash) # unparseable verdict: allow

unless v["breach"]
  exit 0 # below threshold or unknown reading: allow, same as the Stop hook
end

# Which model served this session — same reading the Stop hook uses. A
# custom-model session spends the custom provider, not the plan, so its
# spawns are allowed even mid-breach; unknown keeps the fail-safe deny.
scan_entries = lambda do |lines|
  lines.reverse_each do |line|
    d = (JSON.parse(line) rescue nil)
    next unless d.is_a?(Hash)
    next if d["isSidechain"]
    m = d["message"]
    next unless m.is_a?(Hash)
    mid = m["model"]
    return mid if mid.is_a?(String) && !mid.strip.empty?
  end
  nil
end
model_kind = "unknown"
begin
  tp = ENV["TRANSCRIPT_PATH"].to_s
  raise StandardError, "no transcript" if tp.empty? || !File.exist?(tp)

  size = File.size(tp)
  mid =
    if size > 65_536
      tail = File.open(tp, "rb") { |f| f.seek(size - 65_536); f.read.to_s.lines }
      scan_entries.(tail) || scan_entries.(File.readlines(tp))
    else
      scan_entries.(File.readlines(tp))
    end
  model_kind = mid.match?(/\Aclaude-/i) ? "native" : "custom" if mid
rescue StandardError
end
exit 0 if model_kind == "custom"

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

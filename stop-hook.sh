#!/usr/bin/env bash
# usage-guard Stop hook.
#
# Runs after each Claude Code response. Evaluates the guard and, on breach,
# writes a standdown marker that the /usage-guard-tick loop and the status line
# can read, and surfaces a one-line warning to the session via systemMessage.
# On no breach it clears any stale marker. Never blocks the stop.
set -uo pipefail

DIR="$HOME/.claude/usage-guard"
VERDICT="$("$DIR/guard.sh" 2>/dev/null)"
[ -z "$VERDICT" ] && exit 0

printf '%s' "$VERDICT" | ruby -rjson -e '
v = (JSON.parse(STDIN.read) rescue {})
dir = File.expand_path("~/.claude/usage-guard")
marker = File.join(dir, "standdown.json")
pct = ->(x) { x.nil? ? "?" : x.round }
if v["breach"]
  File.write(marker, JSON.generate(v))
  msg = "usage-guard: headroom low (5h=#{pct.(v["remaining_5h"])}% 7d=#{pct.(v["remaining_7d"])}%, " \
        "limit #{pct.(v["stop_at_remaining"])}%). Stand down until #{v["wake_at_iso"]}."
  puts JSON.generate({"systemMessage" => msg})
else
  File.delete(marker) if File.exist?(marker)
end
'
exit 0

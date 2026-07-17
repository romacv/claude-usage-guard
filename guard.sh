#!/usr/bin/env bash
# usage-guard detector.
#
# Pure CONSUMER of the usage cache produced by claude-plan-usage-statusline
# (its refresh-usage-cache.sh writes /tmp/claude_usage_cache.json from the
# Anthropic OAuth usage API). This script never calls the API itself.
#
# Prints a one-line JSON verdict on stdout and always exits 0:
#   {"breach":false,...}
#   {"breach":true,"window":"5h+7d","remaining_5h":..,"remaining_7d":..,
#    "wake_at_epoch":..,"wake_at_iso":"..","seconds_until_wake":..}
#
# A breach means: on at least one enabled window, the remaining headroom
# (100 - utilization) has dropped to <= stop_at_remaining. wake_at is the
# LATEST reset among breached windows plus resume_grace_seconds, because you
# only regain headroom once the slowest breached window has reset.
#
# Config precedence: $USAGE_GUARD_STOP_AT env > config.json > built-in default.
set -uo pipefail

CACHE_FILE="${USAGE_GUARD_CACHE:-/tmp/claude_usage_cache.json}"
CONFIG_FILE="${USAGE_GUARD_CONFIG:-$HOME/.claude/usage-guard/config.json}"

ruby -rjson -rtime -e '
cache, config = ARGV
stop_env = ENV["USAGE_GUARD_STOP_AT"]

cfg = (File.exist?(config) ? (JSON.parse(File.read(config)) rescue {}) : {})
stop_at   = (stop_env || cfg["stop_at_remaining"] || 10).to_f
grace     = (cfg["resume_grace_seconds"] || 60).to_i
windows   = cfg["windows"] || ["5h", "7d"]

def emit(h); puts JSON.generate(h); exit 0; end

unless File.exist?(cache)
  emit({"breach" => false, "reason" => "no_cache", "stop_at_remaining" => stop_at})
end
data = (JSON.parse(File.read(cache)) rescue nil)
emit({"breach" => false, "reason" => "bad_cache", "stop_at_remaining" => stop_at}) if data.nil?

pick = ->(*keys) { keys.each { |k| return data[k] if data[k].is_a?(Hash) }; nil }
util = ->(w) { w && (w["utilizationPercentage"] || w["utilization_percentage"] || w["utilization"]) }
reset = ->(w) { w && (w["resetsAt"] || w["resets_at"]) }

fh = pick.("five_hour", "standardRateLimit", "standard")
wk = pick.("seven_day", "weeklyRateLimit", "weekly")

u5 = util.(fh); u7 = util.(wk)
rem5 = u5.nil? ? nil : (100 - u5.to_f)
rem7 = u7.nil? ? nil : (100 - u7.to_f)

# If none of the enabled windows is readable (e.g. the cache holds an API error
# payload), this is an unknown reading, not a real no-breach. Flag it so the Stop
# hook leaves any active pause untouched instead of lifting it on a blip.
readable = windows.map { |w| w == "5h" ? rem5 : (w == "7d" ? rem7 : nil) }.compact
if readable.empty?
  emit({"breach" => false, "reason" => "no_data", "remaining_5h" => rem5, "remaining_7d" => rem7, "stop_at_remaining" => stop_at})
end

breached = []
if windows.include?("5h") && !rem5.nil? && rem5 <= stop_at
  breached << ["5h", rem5, reset.(fh)]
end
if windows.include?("7d") && !rem7.nil? && rem7 <= stop_at
  breached << ["7d", rem7, reset.(wk)]
end

if breached.empty?
  emit({"breach" => false, "remaining_5h" => rem5, "remaining_7d" => rem7, "stop_at_remaining" => stop_at})
end

now = Time.now.to_i
resets = breached.map { |_, _, r| (Time.parse(r).to_i rescue nil) }.compact
wake = (resets.empty? ? now : resets.max) + grace

emit({
  "breach" => true,
  "window" => breached.map { |w, _, _| w }.join("+"),
  "remaining_5h" => rem5,
  "remaining_7d" => rem7,
  "stop_at_remaining" => stop_at,
  "wake_at_epoch" => wake,
  "wake_at_iso" => Time.at(wake).iso8601,
  "seconds_until_wake" => [wake - now, 0].max
})
' "$CACHE_FILE" "$CONFIG_FILE"

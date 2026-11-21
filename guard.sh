#!/usr/bin/env bash
# usage-guard detector.
#
# Pure CONSUMER of the usage cache produced by claude-plan-usage-statusline
# (statusline.rb writes /tmp/claude_usage_cache.json from Claude Code's stdin
# on every render, or from the Anthropic OAuth usage API otherwise). This
# script never calls the API itself.
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
# A cache older than max_age_seconds is treated as an unknown reading
# (reason "stale_cache"), same as no_cache/bad_cache/no_data — the Stop hook
# only clears an active stand-down when reason is nil, so staleness never
# lifts a real pause on its own.
#
# Config precedence: $USAGE_GUARD_STOP_AT env (both windows) > config.json > built-in default (5h 13, 7d 7).
# Same precedence applies to $USAGE_GUARD_MAX_AGE > config.json > built-in default.
set -uo pipefail

CACHE_FILE="${USAGE_GUARD_CACHE:-/tmp/claude_usage_cache.json}"
CONFIG_FILE="${USAGE_GUARD_CONFIG:-$HOME/.claude/usage-guard/config.json}"

ruby -rjson -rtime -rtimeout -e '
cache, config = ARGV
stop_env = ENV["USAGE_GUARD_STOP_AT"]
max_age_env = ENV["USAGE_GUARD_MAX_AGE"]

cfg = (File.exist?(config) ? (JSON.parse(File.read(config)) rescue {}) : {})
limits    = cfg["stop_at_remaining"]
limits    = {"5h" => limits, "7d" => limits} if limits.is_a?(Numeric)
limits    = {"5h" => 13, "7d" => 7}.merge(limits.is_a?(Hash) ? limits : {})
limits    = {"5h" => stop_env, "7d" => stop_env} if stop_env
stop5     = limits["5h"].to_f
stop7     = limits["7d"].to_f
stop_at   = {"5h" => stop5, "7d" => stop7}
grace     = (cfg["resume_grace_seconds"] || 60).to_i
windows   = cfg["windows"] || ["5h", "7d"]
max_age   = (max_age_env || cfg["max_age_seconds"] || 1800).to_i
refresh_every = (cfg["refresh_min_interval_seconds"] || 900).to_i
producer  = File.expand_path("~/.claude/statusline.rb")
stamp     = "#{cache}.refresh"

def emit(h); puts JSON.generate(h); exit 0; end

cache_age = -> { File.exist?(cache) ? (Time.now - File.mtime(cache)).to_i : nil }

refresh = nil
age = cache_age.call
if (age.nil? || age > max_age) && File.exist?(producer)
  recent = File.exist?(stamp) && (Time.now - File.mtime(stamp)) < refresh_every
  if recent
    refresh = (File.read(stamp).strip rescue "")
  else
    File.write(stamp, "attempting") rescue nil
    out = ""
    io = nil
    begin
      io = IO.popen(["ruby", producer, "--refresh-cache", cache], err: File::NULL, pgroup: true)
      out = Timeout.timeout(2) { io.read.to_s.strip }
    rescue Timeout::Error
      (Process.kill("KILL", -io.pid) rescue nil)
      out = "timeout"
    rescue StandardError
      out = "error"
    ensure
      (io.close rescue nil)
    end
    refresh = out.match?(/\A[a-z0-9_]{1,24}\z/) ? out : "failed"
    File.write(stamp, refresh) rescue nil
  end
  refresh = nil if refresh.empty?
  age = cache_age.call
end
extra = refresh ? {"refresh" => refresh} : {}

if age.nil?
  emit({"breach" => false, "reason" => "no_cache", "stop_at_remaining" => stop_at}.merge(extra))
end

if age > max_age
  emit({"breach" => false, "reason" => "stale_cache", "age_seconds" => age, "stop_at_remaining" => stop_at}.merge(extra))
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
if windows.include?("5h") && !rem5.nil? && rem5 <= stop5
  breached << ["5h", rem5, reset.(fh), stop5]
end
if windows.include?("7d") && !rem7.nil? && rem7 <= stop7
  breached << ["7d", rem7, reset.(wk), stop7]
end

if breached.empty?
  emit({"breach" => false, "remaining_5h" => rem5, "remaining_7d" => rem7, "stop_at_remaining" => stop_at})
end

now = Time.now.to_i
resets = breached.map { |_, _, r, _| (Time.parse(r).to_i rescue nil) }.compact
wake = (resets.empty? ? now : resets.max) + grace

emit({
  "breach" => true,
  "window" => breached.map { |w, _, _, _| w }.join("+"),
  "remaining_5h" => rem5,
  "remaining_7d" => rem7,
  "stop_at_remaining" => breached.min_by { |_, rem, _, _| rem }[3],
  "wake_at_epoch" => wake,
  "wake_at_iso" => Time.at(wake).iso8601,
  "seconds_until_wake" => [wake - now, 0].max
})
' "$CACHE_FILE" "$CONFIG_FILE"

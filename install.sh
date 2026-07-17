#!/bin/sh
set -e

# usage-guard installer.
# Installs the detector, Stop hook, and /usage-guard-tick loop command, and
# wires them into ~/.claude/settings.json idempotently. Depends on the usage
# cache produced by claude-plan-usage-statusline; if that producer is missing,
# bootstraps just its refresh script + Stop hook so the guard has data.

BASE_URL="https://raw.githubusercontent.com/romacv/claude-usage-guard/main"
STATUSLINE_URL="https://raw.githubusercontent.com/romacv/claude-plan-usage-statusline/main"
CLAUDE_DIR="$HOME/.claude"
GUARD_DIR="$CLAUDE_DIR/usage-guard"
CMD_DIR="$CLAUDE_DIR/commands"

mkdir -p "$GUARD_DIR" "$CMD_DIR"

curl -fsSL "$BASE_URL/guard.sh"                 -o "$GUARD_DIR/guard.sh"
curl -fsSL "$BASE_URL/stop-hook.sh"             -o "$GUARD_DIR/stop-hook.sh"
curl -fsSL "$BASE_URL/commands/usage-guard-tick.md" -o "$CMD_DIR/usage-guard-tick.md"
chmod +x "$GUARD_DIR/guard.sh" "$GUARD_DIR/stop-hook.sh"

# Config: never clobber an existing one (preserves the user's threshold).
if [ ! -f "$GUARD_DIR/config.json" ]; then
  curl -fsSL "$BASE_URL/config.example.json" -o "$GUARD_DIR/config.json"
fi

# Dependency bootstrap: the cache producer lives in claude-plan-usage-statusline.
BOOTSTRAPPED_REFRESH=0
if [ ! -f "$CLAUDE_DIR/refresh-usage-cache.sh" ]; then
  curl -fsSL "$STATUSLINE_URL/refresh-usage-cache.sh" -o "$CLAUDE_DIR/refresh-usage-cache.sh"
  chmod +x "$CLAUDE_DIR/refresh-usage-cache.sh"
  BOOTSTRAPPED_REFRESH=1
fi

BOOTSTRAPPED_REFRESH="$BOOTSTRAPPED_REFRESH" ruby - <<'RUBY'
require "json"

settings_path = File.expand_path("~/.claude/settings.json")
settings = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}
settings["hooks"] ||= {}
settings["hooks"]["Stop"] ||= []

def has_command?(stop, needle)
  stop.any? { |entry| (entry["hooks"] || []).any? { |h| h["command"].to_s.include?(needle) } }
end

stop = settings["hooks"]["Stop"]

# Bootstrap the cache producer's refresh hook only if we just fetched it and
# nothing already refreshes the cache.
if ENV["BOOTSTRAPPED_REFRESH"] == "1" && !has_command?(stop, "refresh-usage-cache.sh")
  stop << {
    "matcher" => "",
    "hooks" => [{
      "type"    => "command",
      "command" => "bash -c 'nohup bash $HOME/.claude/refresh-usage-cache.sh >/dev/null 2>&1 &'"
    }]
  }
end

# usage-guard's own Stop hook (foreground: its systemMessage must reach the session).
unless has_command?(stop, "usage-guard/stop-hook.sh")
  stop << {
    "matcher" => "",
    "hooks" => [{
      "type"    => "command",
      "command" => "bash $HOME/.claude/usage-guard/stop-hook.sh",
      "timeout" => 5
    }]
  }
end

File.write(settings_path, JSON.pretty_generate(settings))
RUBY

echo "usage-guard installed."
echo "  detector:  $GUARD_DIR/guard.sh"
echo "  config:    $GUARD_DIR/config.json  (stop_at_remaining, windows)"
echo "  loop:      /loop /usage-guard-tick <your work goal>"
echo "Restart Claude Code to apply the Stop hook."

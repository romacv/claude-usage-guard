#!/bin/sh
set -e

# usage-guard installer.
# Installs the detector, Stop hook, cancel helper, and stand-down/resume skill,
# and wires the hook into ~/.claude/settings.json idempotently. Depends on the
# usage cache produced by claude-plan-usage-statusline; if that producer is
# missing, fetches its statusline.rb so guard.sh can refresh a stale cache.

BASE_URL="https://raw.githubusercontent.com/romacv/claude-usage-guard/main"
STATUSLINE_URL="https://raw.githubusercontent.com/romacv/claude-plan-usage-statusline/main"
CLAUDE_DIR="$HOME/.claude"
GUARD_DIR="$CLAUDE_DIR/usage-guard"
SKILL_DIR="$CLAUDE_DIR/skills/usage-guard"

mkdir -p "$GUARD_DIR" "$SKILL_DIR"

curl -fsSL "$BASE_URL/guard.sh"       -o "$GUARD_DIR/guard.sh"
curl -fsSL "$BASE_URL/stop-hook.sh"   -o "$GUARD_DIR/stop-hook.sh"
curl -fsSL "$BASE_URL/pretool-hook.sh" -o "$GUARD_DIR/pretool-hook.sh"
curl -fsSL "$BASE_URL/cancel.sh"      -o "$GUARD_DIR/cancel.sh"
curl -fsSL "$BASE_URL/skill/SKILL.md" -o "$SKILL_DIR/SKILL.md"
chmod +x "$GUARD_DIR/guard.sh" "$GUARD_DIR/stop-hook.sh" "$GUARD_DIR/pretool-hook.sh" "$GUARD_DIR/cancel.sh"

# Config: never clobber an existing one (preserves the user's threshold).
if [ ! -f "$GUARD_DIR/config.json" ]; then
  curl -fsSL "$BASE_URL/config.example.json" -o "$GUARD_DIR/config.json"
fi

# Dependency bootstrap: the cache producer lives in claude-plan-usage-statusline.
if [ ! -f "$CLAUDE_DIR/statusline.rb" ]; then
  curl -fsSL "$STATUSLINE_URL/statusline.rb" -o "$CLAUDE_DIR/statusline.rb"
fi

ruby - <<'RUBY'
require "json"

settings_path = File.expand_path("~/.claude/settings.json")
settings = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}
settings["hooks"] ||= {}
settings["hooks"]["Stop"] ||= []

def has_command?(stop, needle)
  stop.any? { |entry| (entry["hooks"] || []).any? { |h| h["command"].to_s.include?(needle) } }
end

stop = settings["hooks"]["Stop"]

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

# usage-guard's spawn gate: refuse new subagents on the same breach that
# stands the lead down. Scoped to the Agent tool only.
settings["hooks"]["PreToolUse"] ||= []
pretool = settings["hooks"]["PreToolUse"]

def has_pretool_command?(entries, needle)
  entries.any? { |entry| (entry["hooks"] || []).any? { |h| h["command"].to_s.include?(needle) } }
end

unless has_pretool_command?(pretool, "usage-guard/pretool-hook.sh")
  pretool << {
    "matcher" => "Agent",
    "hooks" => [{
      "type"    => "command",
      "command" => "bash $HOME/.claude/usage-guard/pretool-hook.sh",
      "timeout" => 5
    }]
  }
end

settings["hooks"]["PostToolUse"] ||= []
posttool = settings["hooks"]["PostToolUse"]
unless has_command?(posttool, "usage-guard/stop-hook.sh")
  posttool << {
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
echo "  detector:    $GUARD_DIR/guard.sh"
echo "  config:      $GUARD_DIR/config.json  (stop_at_remaining, windows)"
echo "  skill:       $SKILL_DIR/SKILL.md     (STANDDOWN + RESUME + CANCEL protocol)"
echo "  cancel:      $GUARD_DIR/cancel.sh      (cancel a pending stand-down/resume)"
echo "  spawn gate:  $GUARD_DIR/pretool-hook.sh (refuses new subagents on breach)"
echo "  mid-turn:    $GUARD_DIR/stop-hook.sh on PostToolUse (stands down before the hard limit)"
echo "The Stop hook detects low quota and drives the skill automatically."
echo "Restart Claude Code to apply the hooks."

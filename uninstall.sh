#!/bin/sh

# usage-guard uninstaller. Removes usage-guard's own files and its Stop hook.
# Leaves refresh-usage-cache.sh and its Stop hook alone — that cache producer
# belongs to claude-plan-usage-statusline and may be in use by the status line.

CLAUDE_DIR="$HOME/.claude"
GUARD_DIR="$CLAUDE_DIR/usage-guard"

rm -rf "$GUARD_DIR"
rm -f "$CLAUDE_DIR/commands/usage-guard-tick.md"

ruby - <<'RUBY'
require "json"

settings_path = File.expand_path("~/.claude/settings.json")
exit unless File.exist?(settings_path)

settings = JSON.parse(File.read(settings_path))
if settings.dig("hooks", "Stop")
  settings["hooks"]["Stop"].reject! do |entry|
    (entry["hooks"] || []).any? { |h| h["command"].to_s.include?("usage-guard/stop-hook.sh") }
  end
  settings["hooks"].delete("Stop") if settings["hooks"]["Stop"].empty?
  settings.delete("hooks") if settings["hooks"].empty?
end

File.write(settings_path, JSON.pretty_generate(settings))
RUBY

echo "usage-guard removed. Restart Claude Code to apply."
echo "(claude-plan-usage-statusline's refresh hook was left untouched.)"

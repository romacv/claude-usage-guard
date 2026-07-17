#!/usr/bin/env bash
# usage-guard: cancel a pending stand-down / resume.
#
# Clears a session's stand-down marker + resume checkpoint and mutes that session
# so it will not immediately stand down again while still in breach. Effect:
#   - the status line pause segment clears (its marker is gone);
#   - any scheduled resume becomes a no-op — the RESUME protocol aborts when its
#     checkpoint is absent, so the cron fires into nothing;
#   - an `off-<session_id>` mute is dropped, so the next Stop hook does nothing
#     for that session (remove the mute to re-arm: rm ~/.claude/usage-guard/off-*).
#
# Usage:
#   cancel.sh                list sessions currently standing down
#   cancel.sh <session_id>   cancel that session's stand-down
#   cancel.sh --all          cancel every session currently standing down
#
# The resume itself is a session-only cron the agent scheduled with CronCreate;
# it lives in Claude's memory, not on disk, so this script cannot delete it — and
# does not need to (a resume with no checkpoint aborts cleanly). To drop the cron
# immediately rather than let it fire into a no-op, have the agent CronDelete its
# id.
set -uo pipefail

DIR="$HOME/.claude/usage-guard"

active_sessions() {
  for f in "$DIR"/standdown-*.json "$DIR"/resume-*.json; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    sid="${base#standdown-}"; sid="${sid#resume-}"; sid="${sid%.json}"
    printf '%s\n' "$sid"
  done | sort -u
}

cancel_one() {
  safe="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_-')"
  [ -n "$safe" ] || { echo "cancel: invalid session id" >&2; return 1; }
  rm -f "$DIR/standdown-$safe.json" "$DIR/resume-$safe.json"
  : > "$DIR/off-$safe"
  echo "cancelled $safe — state cleared, muted (off-$safe; rm to re-arm)"
}

case "${1:-}" in
  "")
    sids="$(active_sessions)"
    if [ -z "$sids" ]; then
      echo "(no sessions currently standing down)"
    else
      echo "sessions currently standing down:"
      printf '%s\n' "$sids"
      echo "cancel one with:  cancel.sh <session_id>   (or --all)"
    fi
    ;;
  --all)
    sids="$(active_sessions)"
    [ -n "$sids" ] || { echo "(no sessions currently standing down)"; exit 0; }
    printf '%s\n' "$sids" | while IFS= read -r sid; do cancel_one "$sid"; done
    ;;
  *)
    cancel_one "$1"
    ;;
esac

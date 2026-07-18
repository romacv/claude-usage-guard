#!/usr/bin/env bash
# usage-guard: cancel a pending stand-down / resume.
#
# Clears a session's stand-down marker + resume checkpoint. Effect:
#   - the status line pause segment clears (its marker is gone);
#   - any scheduled resume becomes a no-op — the RESUME protocol aborts when its
#     checkpoint is absent, so the cron fires into nothing.
# NOTE: there is NO mute mechanism — the usage-guard is always armed. If the
# session is still in breach, the next Stop hook stands down again (graceful
# pause + auto-resume); cancel does not and cannot silence the guard.
#
# Usage:
#   cancel.sh                list sessions currently standing down
#   cancel.sh <session_id>   cancel that session's stand-down
#   cancel.sh --all          cancel every session currently standing down
#
# The resume itself is a session-only cron the agent scheduled with CronCreate;
# it lives in Claude's memory, not on disk, so this script cannot delete it — and
# does not need to (a resume with no checkpoint aborts cleanly). It CAN, however,
# surface the cron's id (the STANDDOWN protocol records it in the checkpoint as
# resume_cron_id), so the owning window can CronDelete it precisely instead of
# guessing. A session-only cron can only be removed from the window that made it;
# from any other window, close that window to kill its cron.
set -uo pipefail

DIR="$HOME/.claude/usage-guard"

# Read resume_cron_id from a session's checkpoint, if present. Ruby is a package
# dependency (guard.sh, install.sh, uninstall.sh all use it), so parse JSON with it.
cron_id_for() {
  rf="$DIR/resume-$1.json"
  [ -f "$rf" ] || return 0
  ruby -rjson -e 'begin; v=JSON.parse(File.read(ARGV[0]))["resume_cron_id"]; print v if v && v.to_s != ""; rescue; end' "$rf" 2>/dev/null
}

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
  cid="$(cron_id_for "$safe")"
  rm -f "$DIR/standdown-$safe.json" "$DIR/resume-$safe.json"
  echo "cancelled $safe — state cleared"
  [ -n "$cid" ] && echo "  its resume cron was $cid — CronDelete it from that window (session-only crons can't be removed cross-window)"
  return 0
}

case "${1:-}" in
  "")
    sids="$(active_sessions)"
    if [ -z "$sids" ]; then
      echo "(no sessions currently standing down)"
    else
      echo "sessions currently standing down:"
      printf '%s\n' "$sids" | while IFS= read -r sid; do
        cid="$(cron_id_for "$sid")"
        if [ -n "$cid" ]; then echo "  $sid   (resume cron: $cid)"; else echo "  $sid"; fi
      done
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

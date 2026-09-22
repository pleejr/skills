#!/usr/bin/env bash
#
# idle.sh — the idle stamp behind the status line's ⏳ segment.
#
#   idle.sh stamp   # Stop hook: the session is now waiting for input
#   idle.sh clear   # UserPromptSubmit hook: the wait ended
#   idle.sh clean   # SessionEnd hook: drop this session's files
#
# Reads the hook payload on stdin for .session_id, so the stamp is per session.
# Deterministic — `date`, `jq` and file writes, never `claude` — and silent:
# it prints nothing on any path, so no hook of it can inject into the
# transcript. Always exits 0; a status line's timer is never worth failing a
# hook over.
set -uo pipefail

mode="${1:-}"
payload="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // "default"' 2>/dev/null)"
[ -n "$sid" ] || sid=default

T="${TMPDIR:-/tmp}"
idle_file="$T/.claude-idle-start-${sid}"
frame_file="$T/.claude-statusline-frame-${sid}"

case "$mode" in
  stamp) date +%s > "$idle_file" 2>/dev/null || true ;;
  clear) rm -f "$idle_file" 2>/dev/null || true ;;
  clean) rm -f "$idle_file" "$frame_file" 2>/dev/null || true ;;
  *)     ;;
esac
exit 0

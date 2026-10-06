#!/usr/bin/env bash
# session-hook.sh — the plugin-updates SessionStart hook. Runs check.py and hands its JSON to
# Claude Code: the one-line report to the user as `systemMessage`, the update offer to the model
# as `additionalContext`. NEVER calls `claude`; always exits 0, so it cannot block session start.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
command -v python3 >/dev/null 2>&1 || { printf '{"systemMessage":"plugin-updates: python3 not found; plugins not checked"}\n'; exit 0; }
python3 "$here/check.py" --hook < /dev/null 2>/dev/null
exit 0

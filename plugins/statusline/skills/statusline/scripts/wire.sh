#!/usr/bin/env bash
#
# wire.sh — point settings.json at this plugin's status line, and take it back out.
#
#   wire.sh status            # what is wired right now
#   wire.sh wire [opts]       # set statusLine to this plugin's statusline.sh
#   wire.sh unwire            # restore whatever was there before, or remove the key
#   wire.sh heal              # repoint OUR command after a version bump; silent otherwise
#
# Options: --interval N (refreshInterval, default 1; 0 leaves it unset)
#          --padding N  (statusLine.padding)
#          --settings PATH (default $CLAUDE_CONFIG_DIR/settings.json, else ~/.claude/settings.json)
#
# Why a script at all: Claude Code allows exactly ONE statusLine and a plugin
# cannot provide it — a plugin's own settings.json supports only `agent` and
# `subagentStatusLine`. So enabling this plugin is not the wiring; this is.
#
# The command written carries a marker env assignment:
#
#   CC_STATUSLINE=pleejr "<plugin root>/skills/statusline/scripts/statusline.sh"
#
# The marker, not the path, is what says the entry is ours — the install path
# carries the plugin version, so it moves on every update and `heal` is what
# follows it. A statusLine WITHOUT the marker is somebody else's and is never
# rewritten or removed; `wire` replaces it only because you asked, and saves it
# first so `unwire` can put it back.
#
# Deterministic: jq and file writes, never `claude`. Backs settings.json up
# before any write. `heal` exits 0 whatever it finds, so it cannot block a
# session start.
set -uo pipefail

MARKER="CC_STATUSLINE=pleejr"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$here/statusline.sh"
DESIRED="$MARKER \"$SCRIPT\""

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CFG/settings.json"
STATE="${CLAUDE_PLUGIN_DATA:-$CFG/statusline}"
PREV="$STATE/previous-statusline.json"
INTERVAL=1
PADDING=""

mode="${1:-status}"; shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2;;
    --padding)  PADDING="$2";  shift 2;;
    --settings) SETTINGS="$2"; shift 2;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "wire.sh: unknown argument: $1" >&2; exit 2;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "wire.sh: jq not found" >&2; [ "$mode" = heal ] && exit 0; exit 1; }
[ -f "$SETTINGS" ] || { echo "wire.sh: no settings file at $SETTINGS" >&2; [ "$mode" = heal ] && exit 0; exit 1; }
jq -e . "$SETTINGS" >/dev/null 2>&1 || { echo "wire.sh: $SETTINGS is not valid JSON; refusing to write" >&2; [ "$mode" = heal ] && exit 0; exit 1; }

current="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)"
is_ours=0
case "$current" in *"$MARKER"*) is_ours=1;; esac

write() {  # write <jq filter> [extra jq args...]
  local filter="$1"; shift
  local tmp backup
  backup="${SETTINGS}.bak-statusline-$(date +%Y%m%dT%H%M%S)"
  cp "$SETTINGS" "$backup" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/statusline-settings.XXXXXX")" || return 1
  jq --arg cmd "$DESIRED" --arg iv "${INTERVAL:-1}" --arg pad "${PADDING:-0}" \
     "$@" "$filter" "$SETTINGS" > "$tmp" || { rm -f "$tmp"; return 1; }
  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$SETTINGS" && rm -f "$tmp"
}

case "$mode" in
  status)
    if   [ -z "$current" ]; then echo "statusline: no statusLine set in $SETTINGS"
    elif [ "$is_ours" = 1 ]; then
      echo "statusline: wired -> $current"
      [ "$current" = "$DESIRED" ] || echo "statusline: path is stale; run 'wire.sh heal'"
      [ -f "$PREV" ] && echo "statusline: it replaced $(jq -r '.command // "(none)"' "$PREV" 2>/dev/null)"
    else echo "statusline: a different statusLine is set -> $current"
    fi
    ;;

  wire)
    if [ "$is_ours" = 1 ] && [ "$current" = "$DESIRED" ]; then
      echo "statusline: already wired -> $DESIRED"; exit 0
    fi
    if [ -n "$current" ] && [ "$is_ours" = 0 ]; then
      mkdir -p "$STATE" && jq '.statusLine' "$SETTINGS" > "$PREV" || true
      echo "statusline: replacing $current (saved for unwire)"
    fi
    filter='.statusLine = {type: "command", command: $cmd}'
    [ "${INTERVAL:-0}" != "0" ] && filter="$filter | .statusLine.refreshInterval = (\$iv|tonumber)"
    [ -n "$PADDING" ]           && filter="$filter | .statusLine.padding = (\$pad|tonumber)"
    write "$filter" \
      && echo "statusline: wired -> $DESIRED" \
      || { echo "wire.sh: write failed; settings unchanged" >&2; exit 1; }
    ;;

  unwire)
    if [ "$is_ours" = 0 ]; then
      echo "statusline: not wired to this plugin; leaving ${current:-the empty statusLine} alone"; exit 0
    fi
    if [ -f "$PREV" ] && jq -e . "$PREV" >/dev/null 2>&1; then
      write '.statusLine = $prev' --argjson prev "$(cat "$PREV")" && rm -f "$PREV" \
        && echo "statusline: restored the previous statusLine"
    else
      write 'del(.statusLine)' && echo "statusline: removed the statusLine"
    fi
    ;;

  heal)
    [ "${STATUSLINE_HEAL:-1}" = "0" ] && exit 0
    [ "$is_ours" = 1 ] || exit 0
    [ "$current" = "$DESIRED" ] && exit 0
    write '.statusLine.command = $cmd' && echo "statusline: repointed to $SCRIPT"
    exit 0
    ;;

  *) echo "wire.sh: unknown mode: $mode (status|wire|unwire|heal)" >&2; exit 2;;
esac

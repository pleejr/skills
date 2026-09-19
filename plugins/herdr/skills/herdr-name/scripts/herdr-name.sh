#!/usr/bin/env bash
# herdr-name.sh — apply, clear, and inspect an on-demand Herdr space name.
#
# This script holds no judgement. The `herdr-name` skill decides what the label
# and topic should say; this script only applies them and remembers what the
# space was called first, so a later session can put the original name back.
#
# The label is a real `herdr workspace rename` and never expires. The topic is
# display-only workspace metadata, which Herdr caps at a 24h TTL — long enough
# to outlive the session that set it, which is all this design needs.
#
# Every path exits 0. A naming failure must never break a turn or a session.

set -uo pipefail

STATE_DIR="${HERDR_NAME_STATE_DIR:-$HOME/.claude/state/herdr-name}"
SOURCE_ID="herdr:claude-name"
# Both sidebar fields cut off at 32 characters. Fit the strings here, on whole
# word boundaries, rather than let the surface cut one in half.
LABEL_MAX=32
TOPIC_MAX=32

die_quiet() { exit 0; }

usage() {
  cat >&2 <<'EOF'
usage: herdr-name.sh set <LABEL> <TOPIC>   apply a 1-2 word label and a 4-5 word topic
       herdr-name.sh reset                 restore the original label, clear the topic
       herdr-name.sh show                  print current label, topic, saved original
       herdr-name.sh session-start         hook entry: reset only on a genuinely new session
EOF
  exit 2
}

# --- guards -----------------------------------------------------------------
# Never touch a Herdr session we are not actually inside of.
require_herdr() {
  [ "${HERDR_ENV:-}" = "1" ] || die_quiet
  [ -n "${HERDR_WORKSPACE_ID:-}" ] || die_quiet
  command -v herdr >/dev/null 2>&1 || die_quiet
  command -v python3 >/dev/null 2>&1 || die_quiet
}

ws() { printf '%s' "$HERDR_WORKSPACE_ID"; }
state_file() { printf '%s/%s.%s' "$STATE_DIR" "$(ws)" "$1"; }

# Collapse whitespace, drop leading dashes (clap would read them as flags),
# then fit the text to the field width by dropping whole trailing words. A half
# word reads as a defect, so the last word that does not fit goes out entirely.
# One exception: a first word longer than the whole field has no word boundary
# to cut on, so it is cut hard — the field limit wins.
normalize() {
  printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//' -e 's/^-*//'
}

clean() {
  local text max out word
  local -a words
  text=$(normalize "$1")
  max="$2"

  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
    return
  fi

  out=""
  IFS=' ' read -r -a words <<<"$text"
  for word in "${words[@]}"; do
    if [ -z "$out" ]; then
      [ "${#word}" -le "$max" ] || break
      out="$word"
    elif [ "$(( ${#out} + 1 + ${#word} ))" -le "$max" ]; then
      out="$out $word"
    else
      break
    fi
  done

  [ -n "$out" ] || out="${text:0:$max}"
  printf '%s' "$out"
}

current_label() {
  herdr workspace get "$(ws)" 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["result"]["workspace"].get("label") or "")
except Exception:
    pass
'
}

current_topic() {
  herdr workspace get "$(ws)" 2>/dev/null | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin)["result"]["workspace"].get("tokens") or {}).get("topic") or "")
except Exception:
    pass
'
}

# How many panes in this space are hosting a claude agent. A space shared with
# another live session must not have its name reset out from under that session.
claude_pane_count() {
  herdr pane list --workspace "$(ws)" 2>/dev/null | python3 -c '
import json, sys
try:
    panes = json.load(sys.stdin)["result"]["panes"]
    print(sum(1 for p in panes if p.get("agent") == "claude"))
except Exception:
    print(0)
'
}

# --- commands ---------------------------------------------------------------
cmd_set() {
  local label topic orig
  label=$(clean "${1:-}" "$LABEL_MAX")
  topic=$(clean "${2:-}" "$TOPIC_MAX")
  [ -n "$label" ] || die_quiet

  # Report a trim rather than hide it. A dropped word means the skill wrote a
  # string longer than the field, and the caller should shorten and set again.
  [ "$label" = "$(normalize "${1:-}")" ] || \
    printf 'label trimmed to %s chars: %s\n' "$LABEL_MAX" "$label" >&2
  [ "$topic" = "$(normalize "${2:-}")" ] || \
    printf 'topic trimmed to %s chars: %s\n' "$TOPIC_MAX" "$topic" >&2

  mkdir -p "$STATE_DIR" 2>/dev/null || die_quiet

  # Save the pre-session label exactly once, so repeated renames within a
  # session never overwrite the real original with a generated one.
  if [ ! -f "$(state_file orig)" ]; then
    orig=$(current_label)
    [ -n "$orig" ] && printf '%s\n' "$orig" >"$(state_file orig)"
  fi

  herdr workspace rename "$(ws)" "$label" >/dev/null 2>&1 || true

  if [ -n "$topic" ]; then
    printf '%s\n' "$topic" >"$(state_file topic)" 2>/dev/null || true
    herdr workspace report-metadata "$(ws)" \
      --source "$SOURCE_ID" --token "topic=$topic" --ttl-ms 86400000 \
      >/dev/null 2>&1 || true
  fi

  printf 'space %s: %s\n' "$(ws)" "$label"
  [ -n "$topic" ] && printf 'topic: %s\n' "$topic"
  exit 0
}

cmd_reset() {
  local orig count
  count=$(claude_pane_count)
  # 0 or 1 claude panes means this session owns the space. 2+ means a sibling
  # session is live here and its name stays.
  if [ "$count" -gt 1 ] 2>/dev/null; then
    printf 'space %s shared with %s claude panes — name left alone\n' "$(ws)" "$count"
    exit 0
  fi

  herdr workspace report-metadata "$(ws)" \
    --source "$SOURCE_ID" --clear-token topic >/dev/null 2>&1 || true
  rm -f "$(state_file topic)" 2>/dev/null || true

  if [ -f "$(state_file orig)" ]; then
    orig=$(head -n1 "$(state_file orig)" 2>/dev/null)
    if [ -n "$orig" ]; then
      herdr workspace rename "$(ws)" "$orig" >/dev/null 2>&1 || true
      printf 'space %s restored to: %s\n' "$(ws)" "$orig"
    fi
    rm -f "$(state_file orig)" 2>/dev/null || true
  else
    # Nothing saved means this space was never named by us. Guessing a label
    # would be worse than leaving the one the user chose.
    printf 'space %s: no saved original, label left alone\n' "$(ws)"
  fi
  exit 0
}

cmd_show() {
  printf 'workspace: %s\n' "$(ws)"
  printf 'label:     %s\n' "$(current_label)"
  printf 'topic:     %s\n' "$(current_topic)"
  if [ -f "$(state_file orig)" ]; then
    printf 'original:  %s\n' "$(head -n1 "$(state_file orig)" 2>/dev/null)"
  else
    printf 'original:  (none saved — space not named by this session)\n'
  fi
  exit 0
}

# Hook entry point. Claude Code passes the hook payload on stdin; `source`
# distinguishes a genuinely new session from reattaching to an existing one.
# Deciding here rather than with a settings.json matcher keeps the rule in one
# place we control, and survives a matcher string we cannot verify.
cmd_session_start() {
  local src
  src=$(python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("source") or "")
except Exception:
    pass
' 2>/dev/null)

  case "$src" in
    startup|clear) cmd_reset ;;
    # An unparseable or absent payload is treated as a new session; say so, since the
    # failure direction is "reset a resumed session's name".
    "") printf 'session source missing — treating as startup\n' >&2; cmd_reset ;;
    # resume / compact continue work already in progress — keep the name.
    *) printf 'session source %s — name kept\n' "$src"; exit 0 ;;
  esac
}

# --- dispatch ---------------------------------------------------------------
case "${1:-}" in
  set)           require_herdr; shift; [ $# -ge 1 ] || usage; cmd_set "${1:-}" "${2:-}" ;;
  reset)         require_herdr; cmd_reset ;;
  show)          require_herdr; cmd_show ;;
  session-start) require_herdr; cmd_session_start ;;
  ""|-h|--help)  usage ;;
  *)             usage ;;
esac

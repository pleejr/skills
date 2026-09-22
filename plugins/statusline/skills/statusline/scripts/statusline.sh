#!/usr/bin/env bash
#
# statusline.sh — the status line this plugin renders.
#
#   <model> | <cwd basename> | ctx <pct>% [| 5h <pct>% | 7d <pct>%] [| ⠙ N running] [| ⏳ idle <duration>]
#
# Claude Code runs it with the status-line JSON on stdin (model.display_name,
# workspace.current_dir, session_id, context_window, rate_limits) and prints
# whatever it writes to stdout. It is wired into settings.json by wire.sh, not
# by this plugin's hooks.json — Claude Code allows exactly one statusLine and a
# plugin cannot own it.
#
# Every segment past the model and the directory is optional: a field the host
# does not send simply leaves its segment out, because a status line that breaks
# is worse than one that is absent.
#
# Needs: jq, ps, date. Honors NO_COLOR.
set -uo pipefail

payload="$(cat)"

model="$(printf '%s' "$payload" | jq -r '.model.display_name // "Claude"' 2>/dev/null)"
dir="$(printf '%s' "$payload"   | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "$payload"   | jq -r '.session_id // "default"' 2>/dev/null)"

base="$(basename "${dir:-$PWD}")"

if [ -n "${NO_COLOR:-}" ]; then
  RED=""; AMBER=""; GREEN=""; DIM=""; CYAN=""; RESET=""
else
  RED=$'\033[31m'; AMBER=$'\033[33m'; GREEN=$'\033[1;32m'
  DIM=$'\033[2m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
fi

# Context-window usage: dim while there is room, amber at 70%, red at 85%, and it
# names the action rather than just the number. Truncated, not rounded, so 84.9%
# never escalates a band. Vanishes entirely on a client that doesn't send the
# field, or on null / non-numeric input.
ctx_frag=""
ctx="$(printf '%s' "$payload" | jq -r '.context_window.used_percentage // empty' 2>/dev/null | cut -d. -f1)"
if [ -n "$ctx" ] && [ "$ctx" -eq "$ctx" ] 2>/dev/null; then
  if   [ "$ctx" -ge 85 ]; then ctx_frag=" | ${RED}ctx ${ctx}% — checkpoint now${RESET}"
  elif [ "$ctx" -ge 70 ]; then ctx_frag=" | ${AMBER}ctx ${ctx}% — checkpoint soon${RESET}"
  else                         ctx_frag=" | ${GREEN}ctx ${ctx}%${RESET}"
  fi
fi

# Subscription usage — the 5-hour session window and the 7-day window, read from
# .rate_limits. The host sends it only on a subscription (or behind a gateway that
# reports a spend limit), and only after the session's first API response; before
# that these segments are simply absent. Same bands as ctx, same truncation.
usage_frag=""
for window in five_hour:5h seven_day:7d spend_limit:spend; do
  key="${window%%:*}"; label="${window##*:}"
  pct="$(printf '%s' "$payload" | jq -r ".rate_limits.${key}.used_percentage // empty" 2>/dev/null | cut -d. -f1)"
  [ -n "$pct" ] || continue
  [ "$pct" -eq "$pct" ] 2>/dev/null || continue
  if   [ "$pct" -ge 85 ]; then usage_frag="${usage_frag} | ${RED}${label} ${pct}%${RESET}"
  elif [ "$pct" -ge 70 ]; then usage_frag="${usage_frag} | ${AMBER}${label} ${pct}%${RESET}"
  else                         usage_frag="${usage_frag} | ${DIM}${label} ${pct}%${RESET}"
  fi
done

# Idle timer — appears only while the session is waiting for your input. It reads
# an "idle since" epoch stamped by this plugin's Stop hook and cleared by its
# UserPromptSubmit hook the moment you respond (idle.sh). With
# statusLine.refreshInterval=1 it ticks once per second.
idle=""
idle_file="${TMPDIR:-/tmp}/.claude-idle-start-${sid}"
if [ -f "$idle_file" ]; then
  start="$(cat "$idle_file" 2>/dev/null)"
  if [ -n "$start" ]; then
    secs=$(( $(date +%s) - start ))
    if [ "$secs" -ge 0 ]; then
      if [ "$secs" -ge 60 ]; then
        idle="$(printf ' | ⏳ idle %dm%02ds' $((secs / 60)) $((secs % 60)))"
      else
        idle="$(printf ' | ⏳ idle %ds' "$secs")"
      fi
    fi
  fi
fi

# Activity — a spinner while this session has shell work in flight: a
# run_in_background script still running, or a foreground command the session is
# waiting on before it proceeds. The status-line payload carries no such field,
# so this counts the process table instead: children of this session's `claude`
# process launched through a shell snapshot, minus this script's own ancestry.
# Reading live processes means a finished task stops showing without a hook to
# clear any marker. The frame index is per session and advances once per render,
# which statusLine.refreshInterval=1 makes one frame per second.
work_frag=""
chain=""; p=$$; claude_pid=""
for _ in 1 2 3 4 5 6 7 8; do
  case "$p" in ""|0|1) break ;; esac
  chain="${chain} ${p}"
  case "$(ps -o comm= -p "$p" 2>/dev/null)" in
    *claude) claude_pid="$p"; break ;;
  esac
  p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
done
if [ -n "$claude_pid" ]; then
  running="$(ps -eo pid=,ppid=,command= 2>/dev/null | awk -v P="$claude_pid" -v EX=" ${chain} " '
    $2 == P && index($0, "shell-snapshots/snapshot-") > 0 && index(EX, " " $1 " ") == 0 { n++ }
    END { print n + 0 }')"
  if [ "${running:-0}" -gt 0 ] 2>/dev/null; then
    frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    frame_file="${TMPDIR:-/tmp}/.claude-statusline-frame-${sid}"
    i="$(cat "$frame_file" 2>/dev/null)"
    case "$i" in ''|*[!0-9]*) i=0 ;; esac
    i=$(( (i + 1) % ${#frames[@]} ))
    printf '%s' "$i" > "$frame_file" 2>/dev/null || true
    work_frag="$(printf ' | %s%s%s %d running' "$CYAN" "${frames[i]}" "$RESET" "$running")"
  fi
fi

printf '%s | %s%s%s%s%s' "$model" "$base" "$ctx_frag" "$usage_frag" "$work_frag" "$idle"

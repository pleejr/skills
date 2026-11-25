#!/usr/bin/env bash
#
# statusline.sh — the status line this plugin renders.
#
#   <model> | <cwd basename> | ctx <pct>% [| 5h <pct>% | 7d <pct>%] [| sso <left>] [| ⠙ N running] [| ⏳ idle <duration>]
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
# Needs: jq, ps, date (shasum for the opt-in sso segment). Honors NO_COLOR.
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
  if   [ "$ctx" -ge 85 ]; then ctx_frag=" | ${RED}ctx ${ctx}% — distill now${RESET}"
  elif [ "$ctx" -ge 70 ]; then ctx_frag=" | ${AMBER}ctx ${ctx}% — distill soon${RESET}"
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

# AWS SSO — opt-in: set STATUSLINE_AWS_SSO_SESSION to an [sso-session] name from
# ~/.aws/config. Reads the CLI's token cache (file name = sha1 of that name) and
# shows how long the cached access token has left, with no network call. That is
# the access token, not the whole SSO session: the CLI refreshes it with the
# refresh token on next use until the session's own maximum, which the cache does
# not record. Dim above 15m, amber at 15m or under, amber "refresh due" once past
# expiry while the CLI can still refresh, red when it cannot or there is no file.
sso_frag=""
if [ -n "${STATUSLINE_AWS_SSO_SESSION:-}" ]; then
  sso_dir="${STATUSLINE_AWS_SSO_CACHE:-${HOME:-}/.aws/sso/cache}"
  sso_key="$( { printf '%s' "$STATUSLINE_AWS_SSO_SESSION" | shasum 2>/dev/null || printf '%s' "$STATUSLINE_AWS_SSO_SESSION" | sha1sum 2>/dev/null; } | cut -c1-40)"
  sso_file="${sso_dir}/${sso_key}.json"
  sso_hint="aws sso login --sso-session ${STATUSLINE_AWS_SSO_SESSION}"
  if [ -z "$sso_key" ]; then
    :  # no sha1 tool: draw nothing rather than a false alarm
  elif [ ! -r "$sso_file" ]; then
    sso_frag=" | ${RED}sso expired — ${sso_hint}${RESET}"
  else
    # One jq pass: "<seconds left> <refreshable y|n>", or nothing when expiresAt
    # does not parse (an unknown format draws no segment, never a false red).
    # Refreshable mirrors the CLI: a non-empty refresh token plus a client id,
    # secret and a registration that has not yet expired.
    read -r sso_left sso_refresh <<EOF2
$(jq -r '
  def ts: sub("\\.[0-9]+"; "") | fromdateiso8601;
  ((.expiresAt | ts) - now | floor) as $left
  | (if ((.refreshToken // "") != "") and ((.clientId // "") != "") and ((.clientSecret // "") != "")
          and (((.registrationExpiresAt // "") | try ts catch 0) > now)
     then "y" else "n" end) as $r
  | "\($left) \($r)"' "$sso_file" 2>/dev/null)
EOF2
    if [ -n "${sso_left:-}" ] && [ "$sso_left" -eq "$sso_left" ] 2>/dev/null; then
      if [ "$sso_left" -gt 0 ]; then
        sso_min=$(( sso_left / 60 ))
        if [ "$sso_left" -ge 3600 ]; then
          sso_txt="$(printf 'sso %dh%02dm' $((sso_left / 3600)) $((sso_min % 60)))"
        else
          sso_txt="sso ${sso_min}m"
        fi
        # Band on the shown minutes, so one label never wears two colours; 15m
        # is the CLI's own refresh window.
        if [ "$sso_min" -le 15 ]; then sso_frag=" | ${AMBER}${sso_txt}${RESET}"
        else                           sso_frag=" | ${DIM}${sso_txt}${RESET}"
        fi
      elif [ "$sso_refresh" = "y" ]; then
        sso_frag=" | ${AMBER}sso refresh due${RESET}"
      else
        sso_frag=" | ${RED}sso expired — ${sso_hint}${RESET}"
      fi
    fi
  fi
fi

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

printf '%s | %s%s%s%s%s%s' "$model" "$base" "$ctx_frag" "$usage_frag" "$sso_frag" "$work_frag" "$idle"

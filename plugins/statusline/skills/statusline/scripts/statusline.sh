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
# Needs: jq, ps, date (shasum and aws for the opt-in sso segment). Honors NO_COLOR.
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
# ~/.aws/config. Shows time left on the SSO session itself, not the 1-hour access
# token the CLI renews on its own:
#   session clock  login stamp (sso.sh login, or a launcher writing the same file)
#                  + STATUSLINE_AWS_SSO_HOURS (default 8, the Identity Center default)
#   live check     sso.sh check, started detached at most every 5 minutes when
#                  STATUSLINE_AWS_SSO_PROFILE names a profile on that session
#   renewal        in the final hour, sso.sh login runs detached (at most every
#                  30 minutes) and opens the browser for you to approve
# Dim above an hour, amber "renewing" in the last hour, red when the live check
# says the session is gone or the token cache cannot refresh. No stamp yet: a dim
# "sso ok". Nothing here waits on the network; the render reads files only.
sso_frag=""
if [ -n "${STATUSLINE_AWS_SSO_SESSION:-}" ]; then
  here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  sso_sess="$STATUSLINE_AWS_SSO_SESSION"
  sso_safe="$(printf '%s' "$sso_sess" | tr -c 'A-Za-z0-9._-' '_')"
  sso_state="${STATUSLINE_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/claude-statusline}"
  sso_hours="${STATUSLINE_AWS_SSO_HOURS:-8}"
  case "$sso_hours" in ''|*[!0-9]*) sso_hours=8 ;; esac
  sso_now="$(date +%s)"
  sso_hint="aws sso login --sso-session ${sso_sess}"
  sso_bg() { nohup "$here/sso.sh" "$@" </dev/null >/dev/null 2>&1 & }

  # Live check, throttled by rewriting the check file's epoch before starting one.
  sso_check="$sso_state/sso-check-$sso_safe"
  read -r sso_ck_at sso_ck <<<"$(cat "$sso_check" 2>/dev/null)"
  case "${sso_ck_at:-}" in ''|*[!0-9]*) sso_ck_at=0 ;; esac
  if [ -n "${STATUSLINE_AWS_SSO_PROFILE:-}" ] && [ $(( sso_now - sso_ck_at )) -ge 300 ] \
     && mkdir -p "$sso_state" 2>/dev/null; then
    printf '%s %s\n' "$sso_now" "${sso_ck:-}" > "$sso_check" 2>/dev/null \
      && sso_bg check "$sso_sess" "$STATUSLINE_AWS_SSO_PROFILE"
  fi

  # Token cache: whether the CLI can still refresh (refresh token plus a live client
  # registration, its own rule) and whether the access token is still in date.
  sso_dir="${STATUSLINE_AWS_SSO_CACHE:-${HOME:-}/.aws/sso/cache}"
  sso_key="$( { printf '%s' "$sso_sess" | shasum 2>/dev/null || printf '%s' "$sso_sess" | sha1sum 2>/dev/null; } | cut -c1-40)"
  sso_cache=missing
  if [ -n "$sso_key" ] && [ -r "$sso_dir/$sso_key.json" ]; then
    sso_cache="$(jq -r '
      def ts: sub("\\.[0-9]+"; "") | fromdateiso8601;
      if ((.refreshToken // "") != "") and ((.clientId // "") != "") and ((.clientSecret // "") != "")
         and (((.registrationExpiresAt // "") | try ts catch 0) > now) then "refreshable"
      elif ((.expiresAt // "") | try ts catch 0) > now then "valid"
      else "dead" end' "$sso_dir/$sso_key.json" 2>/dev/null)"
    [ -n "$sso_cache" ] || sso_cache=unknown
  fi

  sso_start="$(cat "$sso_state/sso-login-$sso_safe" 2>/dev/null)"
  case "$sso_start" in ''|*[!0-9]*) sso_start="" ;; esac

  if [ "${sso_ck:-}" = fail ] || [ "$sso_cache" = missing ] || [ "$sso_cache" = dead ]; then
    sso_frag=" | ${RED}sso expired — ${sso_hint}${RESET}"
  elif [ -n "$sso_start" ]; then
    sso_left=$(( sso_start + sso_hours * 3600 - sso_now ))
    if [ "$sso_left" -gt 3600 ]; then
      sso_frag="$(printf ' | %ssso %dh%02dm%s' "$DIM" $((sso_left / 3600)) $((sso_left % 3600 / 60)) "$RESET")"
    elif [ "$sso_left" -gt 0 ]; then
      sso_frag="$(printf ' | %ssso %dm — renewing%s' "$AMBER" $((sso_left / 60)) "$RESET")"
      sso_relogin="$sso_state/sso-relogin-$sso_safe"
      sso_last="$(cat "$sso_relogin" 2>/dev/null)"
      case "$sso_last" in ''|*[!0-9]*) sso_last=0 ;; esac
      if [ $(( sso_now - sso_last )) -ge 1800 ] && printf '%s\n' "$sso_now" > "$sso_relogin" 2>/dev/null; then
        sso_bg login "$sso_sess"
      fi
    else
      # Past the assumed length but nothing says it ended: the session is longer.
      sso_frag=" | ${DIM}sso ok${RESET}"
    fi
  elif [ "$sso_cache" != unknown ]; then
    sso_frag=" | ${DIM}sso ok${RESET}"
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

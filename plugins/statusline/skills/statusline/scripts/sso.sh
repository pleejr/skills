#!/usr/bin/env bash
#
# sso.sh — background helpers for the status line's opt-in AWS SSO segment.
#
#   sso.sh check <sso-session> <profile>   live check; writes "<epoch> ok|fail|error"
#   sso.sh login <sso-session>             aws sso login; stamps the login time on success
#
# statusline.sh starts these detached, so they print nothing and always exit 0.
# State lives in $STATUSLINE_STATE_DIR (default ~/.local/state/claude-statusline):
#   sso-login-<session>   epoch of the last login seen — the session clock
#   sso-check-<session>   "<epoch> <ok|fail|error>" from the last live check
#   sso-slot-*            one directory per throttle window; mkdir claims it atomically
#
# No `claude` is ever spawned here, so nothing can recurse into a session.
set -uo pipefail
# Claude Code started outside a login shell may not carry Homebrew on PATH.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

state="${STATUSLINE_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/claude-statusline}"
mkdir -p "$state" 2>/dev/null || exit 0
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

case "${1:-}" in
  check)
    sess="${2:-}"; profile="${3:-}"
    [ -n "$sess" ] && [ -n "$profile" ] || exit 0
    file="$state/sso-check-$(safe "$sess")"
    read -r _ prev 2>/dev/null < "$file" || prev=""
    err="$(aws sts get-caller-identity --profile "$profile" --output text 2>&1 >/dev/null)"
    if [ $? -eq 0 ]; then res=ok
    else
      # A network fault is not an expiry; test it first, since the refresh
      # endpoint's URL (".../token") would match the auth patterns below.
      case "$err" in
        *"Could not connect"*|*"Connect timeout"*|*"Read timeout"*|*"Name or service"*|*"nodename nor servname"*) res=error ;;
        *[Tt]oken*|*[Ll]ogin*|*SSO*|*[Uu]nauthorized*|*[Ee]xpired*) res=fail ;;
        *) res=error ;;
      esac
    fi
    printf '%s %s\n' "$(date +%s)" "$res" > "$file" 2>/dev/null
    # fail -> ok proves a fresh login made outside this plugin: start the clock there.
    [ "$prev" = fail ] && [ "$res" = ok ] && date +%s > "$state/sso-login-$(safe "$sess")" 2>/dev/null
    ;;
  login)
    sess="${2:-}"; [ -n "$sess" ] || exit 0
    if aws sso login --sso-session "$sess" >/dev/null 2>&1 </dev/null; then
      date +%s > "$state/sso-login-$(safe "$sess")" 2>/dev/null
      printf '%s ok\n' "$(date +%s)" > "$state/sso-check-$(safe "$sess")" 2>/dev/null
    fi
    ;;
esac
# Drop throttle slots older than a day.
find "$state" -maxdepth 1 -name 'sso-slot-*' -type d -mmin +1440 -exec rmdir {} + 2>/dev/null
exit 0

#!/usr/bin/env bash
#
# sso.sh — background helpers for the status line's opt-in AWS SSO segment.
#
#   sso.sh check <sso-session> <profile>   live check; writes "<epoch> ok|fail|error"
#   sso.sh login <sso-session>             aws sso login; stamps the login time on success
#
# statusline.sh starts these detached, so they print nothing and always exit 0.
# State lives in $STATUSLINE_STATE_DIR (default ~/.local/state/claude-statusline):
#   sso-login-<session>   epoch of the last login made through this plugin or a
#                         launcher that writes the same file — the session clock
#   sso-check-<session>   "<epoch> <ok|fail|error>" from the last live check
#   sso-relogin-<session> epoch of the last background login attempt (throttle)
#
# No `claude` is ever spawned here, so nothing can recurse into a session.
set -uo pipefail

state="${STATUSLINE_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/claude-statusline}"
mkdir -p "$state" 2>/dev/null || exit 0
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

case "${1:-}" in
  check)
    sess="${2:-}"; profile="${3:-}"
    [ -n "$sess" ] && [ -n "$profile" ] || exit 0
    err="$(aws sts get-caller-identity --profile "$profile" --output text 2>&1 >/dev/null)"
    if [ $? -eq 0 ]; then res=ok
    else
      # Only an auth failure means the session is gone; a network fault does not.
      case "$err" in
        *[Tt]oken*|*[Ll]ogin*|*SSO*|*[Uu]nauthorized*|*[Ee]xpired*) res=fail ;;
        *) res=error ;;
      esac
    fi
    printf '%s %s\n' "$(date +%s)" "$res" > "$state/sso-check-$(safe "$sess")" 2>/dev/null
    ;;
  login)
    sess="${2:-}"; [ -n "$sess" ] || exit 0
    if aws sso login --sso-session "$sess" >/dev/null 2>&1 </dev/null; then
      date +%s > "$state/sso-login-$(safe "$sess")" 2>/dev/null
      printf '%s ok\n' "$(date +%s)" > "$state/sso-check-$(safe "$sess")" 2>/dev/null
    fi
    ;;
esac
exit 0

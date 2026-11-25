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
# Write via a temp file and rename, so a render never reads a half-written file.
put() { printf '%s\n' "$2" > "$1.$$" 2>/dev/null && mv -f "$1.$$" "$1" 2>/dev/null; }

case "${1:-}" in
  check)
    sess="${2:-}"; profile="${3:-}"
    [ -n "$sess" ] && [ -n "$profile" ] || exit 0
    file="$state/sso-check-$(safe "$sess")"; stamp="$state/sso-login-$(safe "$sess")"
    started="$(date +%s)"
    read -r _ prev 2>/dev/null < "$file" || prev=""
    # Check the SSO session, not cached role credentials: a scratch HOME with an
    # empty ~/.aws/cli/cache forces GetRoleCredentials through the SSO token, while
    # the symlinked ~/.aws/sso keeps the real token cache (refreshes land there).
    real_home="${HOME:-}"; scratch="$(mktemp -d "${TMPDIR:-/tmp}/sso-check.XXXXXX")" || exit 0
    mkdir -p "$scratch/.aws" && ln -s "$real_home/.aws/sso" "$scratch/.aws/sso"
    err="$(HOME="$scratch" AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-$real_home/.aws/config}" \
      aws sts get-caller-identity --profile "$profile" --output text \
      --cli-connect-timeout 10 --cli-read-timeout 20 2>&1 >/dev/null)"
    rc=$?
    rm -rf "$scratch"
    if [ $rc -eq 0 ]; then res=ok
    else
      # Transport faults first: botocore names the ".../token" endpoint in them,
      # which the auth patterns would otherwise match.
      case "$err" in
        *"Could not connect"*|*"Connect timeout"*|*"Read timeout"*|*"SSL validation failed"*|*"Connection was closed"*) res=error ;;
        *[Tt]oken*|*[Ll]ogin*|*SSO*|*[Uu]nauthorized*|*[Ee]xpired*) res=fail ;;
        *) res=error ;;
      esac
    fi
    # A login that finished while this check ran outranks its result.
    since="$(cat "$stamp" 2>/dev/null)"; case "$since" in ''|*[!0-9]*) since=0 ;; esac
    [ "$since" -ge "$started" ] && exit 0
    put "$file" "$(date +%s) $res"
    # fail -> ok proves a fresh login made outside this plugin: start the clock there.
    [ "$prev" = fail ] && [ "$res" = ok ] && put "$stamp" "$(date +%s)"
    ;;
  login)
    sess="${2:-}"; [ -n "$sess" ] || exit 0
    if aws sso login --sso-session "$sess" >/dev/null 2>&1 </dev/null; then
      put "$state/sso-login-$(safe "$sess")" "$(date +%s)"
      put "$state/sso-check-$(safe "$sess")" "$(date +%s) ok"
    fi
    ;;
esac
# Drop throttle slots older than a day.
find "$state" -maxdepth 1 -name 'sso-slot-*' -type d -mmin +1440 -exec rmdir {} + 2>/dev/null
exit 0

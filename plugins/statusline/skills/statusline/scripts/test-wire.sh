#!/usr/bin/env bash
#
# test-wire.sh — proves the renderer draws what it is given and the wiring
# refuses what is not ours. No network, no writes outside a temp directory:
# every case runs against its own settings.json with --settings.
#
#   ./test-wire.sh
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/statusline-tests.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_PLUGIN_DATA="$tmp/state"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
has()  { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }

full_payload='{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/demo"},"session_id":"T1","context_window":{"used_percentage":86.4},"rate_limits":{"five_hour":{"used_percentage":12.9},"seven_day":{"used_percentage":71.2}}}'
bare_payload='{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/demo"},"session_id":"T2"}'

echo "renderer"
out="$(printf '%s' "$full_payload" | NO_COLOR=1 "$here/statusline.sh")"
has 'Opus 5 | demo' "$out" && ok "model and directory" || bad "model and directory" "$out"
has 'ctx 86% — distill now' "$out" && ok "red band at 85%+, truncated not rounded" || bad "ctx band" "$out"
has '5h 12%' "$out" && has '7d 71%' "$out" && ok "both usage windows" || bad "usage windows" "$out"

out="$(printf '%s' "$bare_payload" | NO_COLOR=1 "$here/statusline.sh")"
has 'ctx' "$out" && bad "absent fields draw no segment" "$out" || ok "absent fields draw no segment"
[ -n "$out" ] && ok "still renders without them" || bad "still renders without them"

echo "aws sso"
sso="$tmp/sso"; st="$tmp/sso-state"; bin="$tmp/bin"; calls="$tmp/aws-calls"
mkdir -p "$sso" "$st" "$bin"; key=edce4a3ad8cff89e4abe65785085c027e3d56f62  # sha1("tsess"), pinned
# A stand-in aws: records each call; AWS_STUB_STS picks the sts outcome.
cat > "$bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$AWS_CALLS"
case "$1 ${AWS_STUB_STS:-ok}" in
  "sts ok") exit 0 ;;
  "sts expired") echo "Error when retrieving token from sso: Token has expired and refresh failed" >&2; exit 255 ;;
  "sts net") echo "Could not connect to the endpoint URL" >&2; exit 255 ;;
  sso*) exit 0 ;;
esac
STUB
chmod +x "$bin/aws"
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now() { date +%s; }
AMB=$'\033[33m'; RD=$'\033[31m'; DM=$'\033[2m'
render() {
  printf '%s' "$bare_payload" | env -u NO_COLOR PATH="$bin:$PATH" AWS_CALLS="$calls" \
    STATUSLINE_AWS_SSO_SESSION=tsess STATUSLINE_AWS_SSO_CACHE="$sso" STATUSLINE_STATE_DIR="$st" "$@" "$here/statusline.sh"
}
waitfor() { for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q "$1" "$calls" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
reset_sso() { rm -f "$st"/* "$calls"; }
cache() {  # cache <access-token offset> <registration offset> [no-refresh]
  local rt='"refreshToken":"r",'; [ "${3:-}" = no-refresh ] && rt=""
  printf '{"expiresAt":"%s",%s"clientId":"c","clientSecret":"s","registrationExpiresAt":"%s"}' \
    "$(iso $(( $(now) + $1 )))" "$rt" "$(iso $(( $(now) + $2 )))" > "$sso/$key.json"
}
recent_ok() { printf '%s ok\n' "$(now)" > "$st/sso-check-tsess"; }

reset_sso; cache 3000 86400; recent_ok; echo $(( $(now) - 5 * 3600 + 90 )) > "$st/sso-login-tsess"
out="$(render)"; has "${DM}sso 3h01m" "$out" && ok "session clock from the login stamp, dim" || bad "session clock from the login stamp, dim" "$out"
out="$(render STATUSLINE_AWS_SSO_HOURS=12)"; has "sso 7h01m" "$out" && ok "session length is a variable" || bad "session length is a variable" "$out"

reset_sso; cache 3000 86400; recent_ok; echo $(( $(now) - 7 * 3600 - 1830 )) > "$st/sso-login-tsess"
out="$(render)"; has "${AMB}sso 29m — renewing" "$out" && ok "amber in the final hour" || bad "amber in the final hour" "$out"
waitfor "sso login --sso-session tsess" && ok "final hour starts a background login" || bad "final hour starts a background login" "$(cat "$calls" 2>/dev/null)"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(cat "$st/sso-login-tsess")" -ge $(( $(now) - 5 )) ] && break; sleep 0.2; done
[ "$(cat "$st/sso-login-tsess")" -ge $(( $(now) - 5 )) ] && ok "a successful login restamps the clock" || bad "a successful login restamps the clock"
rm -f "$calls"; echo $(( $(now) - 7 * 3600 - 1830 )) > "$st/sso-login-tsess"; render >/dev/null; sleep 0.5
[ -f "$calls" ] && bad "background login is throttled" "$(cat "$calls")" || ok "background login is throttled"

reset_sso; cache 3000 86400; recent_ok
out="$(render)"; has "${DM}sso ok" "$out" && ok "no stamp yet: sso ok" || bad "no stamp yet: sso ok" "$out"

reset_sso; cache 3000 86400; echo $(( $(now) - 3630 )) > "$st/sso-login-tsess"
render STATUSLINE_AWS_SSO_PROFILE=tprof AWS_STUB_STS=expired >/dev/null
waitfor "sts get-caller-identity --profile tprof" && ok "stale check starts a live check" || bad "stale check starts a live check"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q fail "$st/sso-check-tsess" 2>/dev/null && break; sleep 0.2; done
out="$(render)"; has "${RD}sso expired — aws sso login --sso-session tsess" "$out" && ok "a failed live check turns red" || bad "a failed live check turns red" "$out"
rm -f "$calls"; render STATUSLINE_AWS_SSO_PROFILE=tprof >/dev/null; sleep 0.5
[ -f "$calls" ] && bad "live check is throttled to 5 minutes" "$(cat "$calls")" || ok "live check is throttled to 5 minutes"

reset_sso; cache 3000 86400; echo $(( $(now) - 3630 )) > "$st/sso-login-tsess"
render STATUSLINE_AWS_SSO_PROFILE=tprof AWS_STUB_STS=net >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q error "$st/sso-check-tsess" 2>/dev/null && break; sleep 0.2; done
out="$(render)"; has "${DM}sso 6h59m" "$out" && ok "a network fault is not an expiry" || bad "a network fault is not an expiry" "$out"

reset_sso; cache -60 86400 no-refresh
out="$(render)"; has "${RD}sso expired" "$out" && ok "no refresh token and expired: red" || bad "no refresh token and expired: red" "$out"
reset_sso; cache -60 -60
out="$(render)"; has "${RD}sso expired" "$out" && ok "expired registration: red" || bad "expired registration: red" "$out"
reset_sso; printf '{"expiresAt":"%s","refreshToken":"r","clientId":"c","clientSecret":"s","registrationExpiresAt":"%s"}' \
  "$(iso $(( $(now) - 60 )) | sed 's/Z$/.123Z/')" "$(iso $(( $(now) + 86400 )) | sed 's/Z$/.5Z/')" > "$sso/$key.json"
out="$(render)"; has "${DM}sso ok" "$out" && ok "fractional seconds parse" || bad "fractional seconds parse" "$out"
reset_sso; rm -f "$sso/$key.json"
out="$(render)"; has "${RD}sso expired" "$out" && ok "no cache file: red" || bad "no cache file: red" "$out"
reset_sso; echo 'not json' > "$sso/$key.json"
out="$(render)"; has 'sso' "$out" && bad "unreadable cache draws nothing" "$out" || ok "unreadable cache draws nothing"
out="$(printf '%s' "$bare_payload" | env -u STATUSLINE_AWS_SSO_SESSION NO_COLOR=1 STATUSLINE_AWS_SSO_CACHE="$sso" "$here/statusline.sh")"
has 'sso' "$out" && bad "no segment unless opted in" "$out" || ok "no segment unless opted in"
out="$(render 2>&1 >/dev/null)"; [ -z "$out" ] && ok "nothing on stderr" || bad "nothing on stderr" "$out"

echo "idle stamp"
idle="${TMPDIR:-/tmp}/.claude-idle-start-T3"; frame="${TMPDIR:-/tmp}/.claude-statusline-frame-T3"
printf '{"session_id":"T3"}' | "$here/idle.sh" stamp
[ -f "$idle" ] && ok "Stop stamps the session's file" || bad "Stop stamps the session's file"
out="$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/x"},"session_id":"T3"}' | NO_COLOR=1 "$here/statusline.sh")"
has '⏳ idle' "$out" && ok "the stamp reaches the status line" || bad "the stamp reaches the status line" "$out"
printf '{"session_id":"T3"}' | "$here/idle.sh" clear
[ -f "$idle" ] && bad "UserPromptSubmit clears it" || ok "UserPromptSubmit clears it"
printf '{"session_id":"T3"}' | "$here/idle.sh" stamp; : > "$frame"
printf '{"session_id":"T3"}' | "$here/idle.sh" clean
[ -f "$idle" ] || [ -f "$frame" ] && bad "SessionEnd drops both files" || ok "SessionEnd drops both files"
out="$(printf '{"session_id":"T3"}' | "$here/idle.sh" stamp)"
[ -z "$out" ] && ok "the hooks print nothing" || bad "the hooks print nothing" "$out"
rm -f "$idle" "$frame"

echo "wiring"
s="$tmp/empty.json"; echo '{"model":"opus"}' > "$s"
"$here/wire.sh" wire --settings "$s" >/dev/null
cmd="$(jq -r '.statusLine.command' "$s")"
has 'CC_STATUSLINE=pleejr' "$cmd" && ok "wire sets a marked command" || bad "wire sets a marked command" "$cmd"
[ "$(jq -r '.statusLine.refreshInterval' "$s")" = "1" ] && ok "refreshInterval 1 by default" || bad "refreshInterval 1 by default"
[ "$(jq -r '.model' "$s")" = "opus" ] && ok "the rest of settings.json survives" || bad "the rest of settings.json survives"
ls "$s".bak-statusline-* >/dev/null 2>&1 && ok "a backup was taken" || bad "a backup was taken"

s="$tmp/foreign.json"; echo '{"statusLine":{"type":"command","command":"/usr/local/bin/mine.sh","padding":2}}' > "$s"
"$here/wire.sh" wire --settings "$s" >/dev/null
has 'CC_STATUSLINE=pleejr' "$(jq -r '.statusLine.command' "$s")" && ok "wire replaces a foreign line when asked" || bad "wire replaces a foreign line when asked"
"$here/wire.sh" unwire --settings "$s" >/dev/null
[ "$(jq -r '.statusLine.command' "$s")" = "/usr/local/bin/mine.sh" ] \
  && [ "$(jq -r '.statusLine.padding' "$s")" = "2" ] \
  && ok "unwire restores it exactly, padding included" || bad "unwire restores it exactly" "$(jq -c '.statusLine' "$s")"

s="$tmp/ours.json"; echo '{}' > "$s"
"$here/wire.sh" wire --settings "$s" >/dev/null
"$here/wire.sh" unwire --settings "$s" >/dev/null
[ "$(jq -r 'has("statusLine")' "$s")" = "false" ] && ok "unwire removes the key when there was nothing before" || bad "unwire removes the key"

echo "heal"
s="$tmp/stale.json"
jq -n '{statusLine:{type:"command",command:"CC_STATUSLINE=pleejr \"/old/version/0.0.1/statusline.sh\"",refreshInterval:1}}' > "$s"
out="$("$here/wire.sh" heal --settings "$s")"
has "$here/statusline.sh" "$(jq -r '.statusLine.command' "$s")" && ok "heal follows a version bump" || bad "heal follows a version bump" "$out"
out="$("$here/wire.sh" heal --settings "$s")"
[ -z "$out" ] && ok "heal is silent once current" || bad "heal is silent once current" "$out"

s="$tmp/theirs.json"; echo '{"statusLine":{"type":"command","command":"/usr/local/bin/mine.sh"}}' > "$s"
out="$("$here/wire.sh" heal --settings "$s")"; rc=$?
[ "$(jq -r '.statusLine.command' "$s")" = "/usr/local/bin/mine.sh" ] && [ -z "$out" ] \
  && ok "heal leaves an unmarked statusLine alone" || bad "heal leaves an unmarked statusLine alone" "$out"
[ "$rc" = 0 ] && ok "heal exits 0 so it cannot block session start" || bad "heal exits 0" "rc=$rc"
"$here/wire.sh" heal --settings "$tmp/does-not-exist.json" >/dev/null 2>&1
[ $? = 0 ] && ok "heal exits 0 with no settings file at all" || bad "heal exits 0 with no settings file"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]

#!/usr/bin/env bash
#
# test-wire.sh — proves the renderer draws what it is given and the wiring
# refuses what is not ours. No network, no writes outside a temp directory:
# every case runs against its own settings.json with --settings.
#
#   ./test-wire.sh
set -uo pipefail
# Hermetic: a launcher's opt-in must never reach real AWS or real state from here.
unset STATUSLINE_AWS_SSO_SESSION STATUSLINE_AWS_SSO_PROFILE STATUSLINE_AWS_SSO_HOURS STATUSLINE_STATE_DIR
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
st="$tmp/sso-state"; bin="$tmp/bin"; calls="$tmp/aws-calls"; mkdir -p "$st" "$bin"
# A stand-in aws: records each call; AWS_STUB_STS picks the sts outcome, with the
# CLI's real messages (an offline refresh names the ".../token" endpoint).
cat > "$bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$AWS_CALLS"
[ "$1" = sts ] && echo "home=$HOME rolecache=$([ -e "$HOME/.aws/cli/cache" ] && echo yes || echo no)" >> "$AWS_CALLS.env"
case "$1 ${AWS_STUB_STS:-ok}" in
  "sts ok") exit 0 ;;
  "sts expired") echo "Error when retrieving token from sso: Token has expired and refresh failed" >&2; exit 255 ;;
  "sts ssl") echo 'SSL validation failed for https://oidc.us-east-1.amazonaws.com/token [SSL: CERTIFICATE_VERIFY_FAILED]' >&2; exit 255 ;;
  "sts net") echo 'Could not connect to the endpoint URL: "https://oidc.us-east-1.amazonaws.com/token"' >&2; exit 255 ;;
  sso*) exit 0 ;;
esac
STUB
chmod +x "$bin/aws"
now() { date +%s; }
AMB=$'\033[33m'; RD=$'\033[31m'; DM=$'\033[2m'
render() {
  printf '%s' "$bare_payload" | env -u NO_COLOR PATH="$bin:$PATH" AWS_CALLS="$calls" STATUSLINE_STATE_DIR="$st" \
    STATUSLINE_AWS_SSO_SESSION=tsess STATUSLINE_AWS_SSO_PROFILE=tprof "$@" "$here/statusline.sh"
}
waitfor() { for _ in $(seq 1 25); do grep -q "$1" "$2" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
reset_sso() { rm -rf "$st"/* "$calls" "$calls.env"; }
stamp() { echo $(( $(now) - $1 )) > "$st/sso-login-tsess"; }
checked() { printf '%s %s\n' "$(now)" "$1" > "$st/sso-check-tsess"; mkdir -p "$st/sso-slot-check-tsess-$(( $(now) / 300 ))"; }

reset_sso; checked ok; stamp $(( 5 * 3600 - 90 ))
out="$(render)"; has "${DM}sso 3h01m" "$out" && ok "session clock from the login stamp, dim" || bad "session clock from the login stamp, dim" "$out"
out="$(render STATUSLINE_AWS_SSO_HOURS=012)"; has "sso 7h01m" "$out" && ok "session length is a variable, leading zero ok" || bad "session length is a variable, leading zero ok" "$out"
out="$(render STATUSLINE_AWS_SSO_HOURS=08 2>&1 >/dev/null)"; [ -z "$out" ] && ok "no stderr on the countdown path" || bad "no stderr on the countdown path" "$out"

reset_sso; checked ok; stamp $(( 7 * 3600 + 1830 ))
out="$(render 2>"$tmp/err")"; has "${AMB}sso 29m — renewing" "$out" && ok "amber in the final hour" || bad "amber in the final hour" "$out"
[ -s "$tmp/err" ] && bad "no stderr on the renewal path" "$(cat "$tmp/err")" || ok "no stderr on the renewal path"
waitfor "sso login --sso-session tsess" "$calls" && ok "final hour starts a background login" || bad "final hour starts a background login"
for _ in $(seq 1 25); do [ "$(cat "$st/sso-login-tsess")" -ge $(( $(now) - 5 )) ] && break; sleep 0.2; done
[ "$(cat "$st/sso-login-tsess")" -ge $(( $(now) - 5 )) ] && ok "a successful login restamps the clock" || bad "a successful login restamps the clock"
stamp $(( 7 * 3600 + 1830 )); render >/dev/null; render >/dev/null; sleep 1
[ "$(grep -c 'sso login' "$calls")" = 1 ] && ok "one background login per 30-minute window" || bad "one background login per 30-minute window" "$(cat "$calls")"

reset_sso; checked ok
out="$(render)"; has "${DM}sso ok" "$out" && ok "no stamp yet: sso ok" || bad "no stamp yet: sso ok" "$out"
reset_sso; checked ok; stamp $(( 9 * 3600 ))
out="$(render)"; has "${DM}sso ok" "$out" && ok "past the assumed length, still passing: sso ok" || bad "past the assumed length: sso ok" "$out"
[ -f "$calls" ] && bad "past the assumed length starts no login" "$(cat "$calls")" || ok "past the assumed length starts no login"

reset_sso; stamp 3630
render AWS_STUB_STS=expired >/dev/null; render AWS_STUB_STS=expired >/dev/null
waitfor "sts get-caller-identity --profile tprof" "$calls" && ok "a new window starts a live check" || bad "a new window starts a live check"
waitfor fail "$st/sso-check-tsess"; sleep 0.5
[ "$(grep -c 'sts' "$calls")" = 1 ] && ok "one live check per 5-minute window" || bad "one live check per 5-minute window" "$(cat "$calls")"
out="$(render)"; has "${RD}sso expired — aws sso login --sso-session tsess" "$out" && ok "a failed live check turns red" || bad "a failed live check turns red" "$out"
out="$(render 2>&1 >/dev/null)"; [ -z "$out" ] && ok "no stderr on the red path" || bad "no stderr on the red path" "$out"

reset_sso; stamp 3630
render AWS_STUB_STS=net >/dev/null; waitfor error "$st/sso-check-tsess"
out="$(render)"; has "${DM}sso 6h59m" "$out" && ok "offline (token endpoint unreachable) is not an expiry" || bad "offline is not an expiry" "$out"

grep -q "rolecache=no" "$calls.env" && ! grep -q "home=$HOME " "$calls.env" && ok "the check runs without cached role credentials" || bad "the check runs without cached role credentials" "$(cat "$calls.env" 2>/dev/null)"
reset_sso; stamp 3630
render AWS_STUB_STS=ssl >/dev/null; waitfor error "$st/sso-check-tsess"
grep -q error "$st/sso-check-tsess" && ok "a TLS fault on the token endpoint is not an expiry" || bad "TLS fault is not an expiry" "$(cat "$st/sso-check-tsess")"

reset_sso; stamp $(( 9 * 3600 )); printf '%s fail\n' "$(( $(now) - 400 ))" > "$st/sso-check-tsess"
render >/dev/null; waitfor ok "$st/sso-check-tsess"; sleep 0.3
[ "$(cat "$st/sso-login-tsess")" -ge $(( $(now) - 5 )) ] && ok "fail then ok restamps: a login made elsewhere" || bad "fail then ok restamps"
reset_sso; stamp $(( 9 * 3600 )); printf '%s ok\n' "$(( $(now) - 400 ))" > "$st/sso-check-tsess"
render >/dev/null; sleep 1
[ "$(cat "$st/sso-login-tsess")" -le $(( $(now) - 9 * 3600 + 5 )) ] && ok "ok then ok leaves the stamp alone" || bad "ok then ok leaves the stamp alone"

reset_sso; out="$(render 2>&1 >/dev/null)"; [ -z "$out" ] && ok "no stderr with no state yet" || bad "no stderr with no state yet" "$out"
reset_sso
out="$(render STATUSLINE_AWS_SSO_PROFILE= )"; has 'sso' "$out" && bad "no profile: no segment" "$out" || ok "no profile: no segment"
[ -f "$calls" ] && bad "no profile: nothing spawned" || ok "no profile: nothing spawned"
out="$(printf '%s' "$bare_payload" | NO_COLOR=1 STATUSLINE_STATE_DIR="$st" "$here/statusline.sh")"
has 'sso' "$out" && bad "no segment unless opted in" "$out" || ok "no segment unless opted in"
reset_sso

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

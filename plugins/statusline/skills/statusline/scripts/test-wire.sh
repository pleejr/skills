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
sso="$tmp/sso"; mkdir -p "$sso"; key=edce4a3ad8cff89e4abe65785085c027e3d56f62  # sha1("tsess"), pinned
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now() { date +%s; }
render() { printf '%s' "$bare_payload" | env -u NO_COLOR STATUSLINE_AWS_SSO_SESSION=tsess STATUSLINE_AWS_SSO_CACHE="$sso" "$here/statusline.sh"; }
AMB=$'\033[33m'; RD=$'\033[31m'; DM=$'\033[2m'
reg="\"clientId\":\"c\",\"clientSecret\":\"s\",\"registrationExpiresAt\":\"$(iso $(( $(now) + 86400 )))\""
printf '{"expiresAt":"%s"}' "$(iso $(( $(now) + 7500 )))" > "$sso/$key.json"
out="$(render)"; has "${DM}sso 2h0" "$out" && ok "hours and minutes left, dim" || bad "hours and minutes left, dim" "$out"
printf '{"expiresAt":"%s"}' "$(iso $(( $(now) + 16 * 60 + 30 )))" > "$sso/$key.json"
out="$(render)"; has "${DM}sso 16m" "$out" && ok "16m stays dim" || bad "16m stays dim" "$out"
printf '{"expiresAt":"%s"}' "$(iso $(( $(now) + 15 * 60 + 50 )))" > "$sso/$key.json"
out="$(render)"; has "${AMB}sso 15m" "$out" && ok "15m turns amber" || bad "15m turns amber" "$out"
printf '{"expiresAt":"%s"}' "$(iso $(( $(now) + 600 )) | sed 's/Z$/.123Z/')" > "$sso/$key.json"
out="$(render)"; has 'sso 9m' "$out" && ok "fractional seconds parse" || bad "fractional seconds parse" "$out"
printf '{"expiresAt":"%s","refreshToken":"r",%s}' "$(iso $(( $(now) - 60 )))" "$reg" > "$sso/$key.json"
out="$(render)"; has "${AMB}sso refresh due" "$out" && ok "expired but refreshable" || bad "expired but refreshable" "$out"
printf '{"expiresAt":"%s","refreshToken":"r","clientId":"c","clientSecret":"s","registrationExpiresAt":"%s"}' "$(iso $(( $(now) - 60 )))" "$(iso $(( $(now) - 60 )))" > "$sso/$key.json"
out="$(render)"; has "${RD}sso expired" "$out" && ok "expired registration cannot refresh" || bad "expired registration cannot refresh" "$out"
printf '{"expiresAt":"%s"}' "$(iso $(( $(now) - 60 )))" > "$sso/$key.json"
out="$(render)"; has 'sso expired — aws sso login --sso-session tsess' "$out" && ok "expired without a refresh token" || bad "expired without a refresh token" "$out"
printf '{"expiresAt":"2030-01-01 00:00:00 UTC"}' > "$sso/$key.json"
out="$(render)"; has 'sso' "$out" && bad "unparseable date draws nothing" "$out" || ok "unparseable date draws nothing"
rm -f "$sso/$key.json"
out="$(render)"; has "${RD}sso expired" "$out" && ok "no cache file reads as expired" || bad "no cache file reads as expired" "$out"
out="$(printf '%s' "$bare_payload" | env -u STATUSLINE_AWS_SSO_SESSION NO_COLOR=1 STATUSLINE_AWS_SSO_CACHE="$sso" "$here/statusline.sh")"
has 'sso' "$out" && bad "no segment unless opted in" "$out" || ok "no segment unless opted in"

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

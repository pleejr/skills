#!/usr/bin/env bash
# session-hook.sh — the machine-config plugin's SessionStart hook. Runs the two checks that the
# legacy install linked into ~/.claude/session-checks.d/ — session-check.sh (snapshot and shared
# settings drift) then session-apply.sh (installs shared output styles) — and hands their output
# to Claude Code as hook JSON: the banner fragments to the user as `systemMessage`, the notes to
# the model as `additionalContext`.
#
# Why not keep the drop-ins: a plugin's path changes on every update, so a link into it goes
# stale, and the drop-in seam belongs to the wiki-engine, which this skill does not require.
#
# Same contract as the drop-ins it wraps: NEVER calls `claude`, no network, always exits 0.
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0

frag=""; notes=""
for chk in session-check.sh session-apply.sh; do
  out="$(bash "$here/$chk" 2>/dev/null)" || true
  [ -n "$out" ] || continue
  f="$(printf '%s\n' "$out" | sed -n '1p')"
  r="$(printf '%s\n' "$out" | sed -n '2,$p')"
  [ -n "$f" ] && frag="${frag:+$frag · }$f"
  [ -n "$r" ] && notes="${notes:+$notes
}$r"
done

[ -n "$frag$notes" ] || exit 0
if command -v jq >/dev/null 2>&1; then
  jq -n --arg sm "${frag:+machine-config: $frag}" --arg ac "$notes" '
    (if $sm == "" then {} else {systemMessage: $sm} end)
    + (if $ac == "" then {} else {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ac}} end)'
else
  # Without jq, plain stdout still reaches the model as context; the user banner is lost.
  printf 'machine-config: %s\n%s\n' "$frag" "$notes"
fi
exit 0

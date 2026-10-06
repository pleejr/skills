#!/usr/bin/env bash
# session-apply.sh — `session-checks.d` drop-in that INSTALLS shared output styles at session
# start and says so in the banner. Installed by install.sh as a SYMLINK, so edits are live.
#
# WHY THIS EXISTS. The stores are synced by whatever syncs them (the skills repo's own
# session-check), but nothing installed what the sync brought down: apply.sh was a command a
# human had to remember, so a style edited on one machine reached the other's DISK and never
# its ~/.claude. Worse, the warn-only drop-in that would have flagged it (session-check.sh)
# runs from the same directory and the loop is glob-ordered — 'machine-config.sh' sorts before
# the skills repo's own drop-in, so it read the store as it was BEFORE that session's sync and reported
# nothing. Hence the install name: `zz-machine-config-apply.sh`, deliberately last.
#
# THIS ONE WRITES, and is the deliberate exception to session-check.sh's "warns, never writes".
# The two are not the same risk. That one wants to snapshot config INTO git, where the secret
# scan is the gate a human should watch fail. This one copies prose OUT of a store that
# already owns it, into ~/.claude/output-styles/, with a backup alongside, and apply.sh
# refuses on its own to overwrite a style this machine did not install. Nothing it does is
# irreversible and nothing it does leaves the machine.
#
# It takes `--styles-only`. Merging settings.json unattended is a wider blast radius than
# anyone asked for; settings drift stays session-check.sh's job to REPORT.
#
# NEVER calls `claude` — the drop-in contract bars it, and this file needs no version probe.
# No network, no git. Always exits 0: a broken drop-in must not break session start.
#
# Contract: first stdout line = compact banner fragment (empty = nothing to report),
# remaining lines = notes for the assistant.
set -uo pipefail

# Resolve through the install symlink to this skill's scripts dir (no `readlink -f` — not
# portable to stock macOS).
self="${BASH_SOURCE[0]}"
invoked_as="$self"
while [ -L "$self" ]; do
  d="$(cd -P "$(dirname "$self")" && pwd)" || exit 0
  self="$(readlink "$self")"
  case "$self" in /*) ;; *) self="$d/$self" ;; esac
done
here="$(cd -P "$(dirname "$self")" && pwd)" || exit 0
[ -f "$here/lib.sh" ] || exit 0
# shellcheck source=lib.sh
. "$here/lib.sh"

# Reached through the legacy session-checks.d link while the plugin runs this same check from
# its own SessionStart hook: stay silent, or every banner would carry it twice.
mc_legacy_standdown "$invoked_as" && exit 0

CFG="$(mc_cfg)"

# Nothing to install from: no store, not our business. mc_skills_repo is derived from this
# script's own location, so the styles half can work on a machine with no config repo at all.
repo="$(mc_repo 2>/dev/null)" || repo=""
[ -n "$repo" ] && [ ! -d "$repo" ] && repo=""
[ -n "$repo" ] || [ -n "$(mc_skills_repo)" ] || exit 0

out="$("$here/apply.sh" --styles-only 2>&1)"
rc=$?

# The two lines that PROVE a write happened, as opposed to the drift lines that precede them.
# Reporting the drift line instead would announce an install that a failed `cp` never made.
changed="$(printf '%s\n' "$out" \
  | sed -n -e 's/^apply: installed .*\/\(.*\)$/\1/p' \
           -e 's/^apply: updated \(.*\) (backup alongside)$/\1/p' \
  | sed 's#.*/##' | sort -u | tr '\n' ' ')"
changed="${changed% }"

# Styles the styles plugin took over: apply.sh removed this machine's copy, and prints the
# setting's old and new names. Pairs, one per line: <old name><TAB><new name>.
taken="$(printf '%s\n' "$out" | sed -n 's/^apply:   a setting of "outputStyle": "\(.*\)" must become "\(.*\)"$/\1	\2/p')"

frag=""; notes=""
add_frag() { frag="${frag:+$frag · }$1"; }
add_note() { notes="${notes}$1
"; }

# WHICH STYLE IS ACTIVE decides how loud this is. A style the session is not running can be
# installed silently-ish; the one it IS running was already read from the old file before this
# hook fired, so the session is now provably out of date with its own configuration and only a
# restart fixes it. Precedence: project-local, then project, then user.
active=""
if command -v jq >/dev/null 2>&1; then
  for f in "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.local.json" \
           "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json" \
           "$CFG/settings.json"; do
    [ -f "$f" ] || continue
    v="$(jq -r '.outputStyle // empty' "$f" 2>/dev/null)"
    [ -n "$v" ] && { active="$v"; break; }
  done
fi

if [ -n "$changed" ]; then
  # Match on the stem: settings.json names a style 'Briefing', the file is 'Briefing.md'.
  hit=""
  for n in $changed; do
    [ -n "$active" ] && [ "${n%.md}" = "$active" ] && hit="$n"
  done
  if [ -n "$hit" ]; then
    add_frag "styles: $hit updated — RESTART"
    add_note "ACTION — the output style this session is RUNNING ('$active') was updated on disk just now, after the session had already loaded the old text. This session is following the previous version. Tell the user this FIRST, before any other work, so they can restart now rather than after doing something under stale rules: the fix is to exit and start a new session (or /clear), and nothing else is needed."
  else
    add_frag "styles: $changed installed"
    add_note "NOTE — shared output style(s) installed at session start: $changed. Not the style in use${active:+ (that is '$active')}, so no restart is needed; they take effect whenever one is selected."
  fi
fi

if [ -n "$taken" ]; then
  moved=""; renamed=""
  while IFS="$(printf '\t')" read -r old_n new_n; do
    [ -n "$old_n" ] || continue
    moved="${moved:+$moved, }$new_n"
    [ -n "$active" ] && [ "$active" = "$old_n" ] && renamed="$new_n"
  done <<TAKEN
$taken
TAKEN
  if [ -n "$renamed" ]; then
    add_frag "styles: '$active' is now '$renamed' — rename the setting"
    add_note "ACTION — the output style this session runs ('$active') now ships in the $MC_STYLES_PLUGIN plugin as '$renamed', and this machine's copy was removed. Until the \"outputStyle\" setting that names '$active' is changed to '$renamed', the next session falls back to the default style. Tell the user FIRST and offer to make that one-line edit (project .claude/settings.local.json, project .claude/settings.json, or ~/.claude/settings.json — whichever sets it)."
  else
    add_frag "styles: now from the $MC_STYLES_PLUGIN plugin"
    add_note "NOTE — shared output style(s) now load from the $MC_STYLES_PLUGIN plugin and this machine's copies were removed: $moved. Not the style in use${active:+ (that is '$active')}, so nothing else is needed."
  fi
fi

# rc 3 = applied what it could and refused something. A refusal never resolves itself.
if [ "$rc" -eq 3 ]; then
  add_frag "styles: REFUSED"
  add_note "ACTION — apply.sh refused part of the shared styles here, so this machine is not converging and will not start on its own. Reason follows. If the local copy is the better one, publish it with the machine-config skill's scripts/apply.sh --promote <name> and commit; if the shared one is, take it with scripts/apply.sh --force, which backs the local copy up first. Do not pick for the user:
$(printf '%s\n' "$out" | grep REFUSING | head -4)"
elif [ "$rc" -ne 0 ]; then
  add_frag "styles: apply FAILED"
  add_note "ACTION — the session-start style apply exited $rc, so shared styles are not being installed on this machine. Output follows:
$(printf '%s\n' "$out" | head -4)"
fi

[ -n "$frag" ] || exit 0
printf '%s\n' "$frag"
[ -n "$notes" ] && printf '%s' "$notes"
exit 0

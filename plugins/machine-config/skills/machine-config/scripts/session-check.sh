#!/usr/bin/env bash
# session-check.sh — optional `session-checks.d` drop-in that surfaces snapshot drift in the
# SessionStart banner. Installed by scripts/install.sh as a SYMLINK, so edits are live.
#
# OPTIONAL BY DESIGN. `session-checks.d` is a wiki-engine seam; this skill does not require
# the engine, or any vault. If the directory isn't there, the drop-in is simply never
# installed and everything else in the skill still works.
#
# Contract (when the engine IS present): first stdout line = compact banner fragment (empty =
# nothing to report), remaining lines = notes for the assistant. Always exits 0.
#
# SCOPE: snapshot drift + shared SETTINGS drift. Shared output styles belong to the sibling
# drop-in session-apply.sh, which installs them rather than reporting them.
#
# NEVER calls `claude` — not even `claude --version`, which is why lib.sh reads the version
# from the install symlink. The contract bars it outright, which is stricter than the
# fork-bomb rule needs to be, and deliberately so: it removes the need to re-derive "is this
# subcommand safe?" on every future edit.
#
# WARNS, NEVER WRITES. It reports drift; it does not snapshot. An unattended backup would
# commit config to git with nobody reading it, and the secret scan is the one gate a human
# should be present to see fail. Local only: no network, no git writes.
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

repo="$(mc_repo 2>/dev/null)" || exit 0   # no config repo on this machine: not our business
[ -d "$repo" ] || exit 0
host="$(mc_host)"

# An undeclared machine is a louder problem than a stale snapshot: nothing is being captured
# at all, so losing this machine loses its config outright.
if [ ! -d "$repo/machines/$host" ]; then
  echo "configs: $host not snapshotted"
  echo "ACTION — this machine has no machines/$host/ snapshot in the config repo ($repo), so its Claude config is not recoverable if the machine is lost. Offer to run the machine-config skill's scripts/backup.sh and commit the result."
  exit 0
fi

# Two independent signals, so they accumulate rather than short-circuit: a stale snapshot and
# unapplied shared settings are different problems and either can be the only one present.
frag=""; notes=""
add_frag() { frag="${frag:+$frag · }$1"; }
add_note() { notes="${notes}$1
"; }

out="$("$here/backup.sh" --check 2>&1)"
rc=$?

case "$rc" in
  0) : ;;   # snapshot current — say nothing about it
  1)
    files="$(printf '%s\n' "$out" | sed -n 's/^  \([^:]*\):.*/\1/p' | tr '\n' ' ')"
    add_frag "configs: snapshot stale"
    # "AS OF SESSION START" is load-bearing, not padding. This fires once, at startup, and
    # the finding is then read for the rest of the session — but autosave runs at every
    # SessionEnd, so a CONCURRENT session can commit this exact drift minutes later and the
    # note goes on describing a state that no longer exists. Acting on it an hour in then
    # produces a confusing no-op that reads as the check having been wrong. It was not; it
    # was old. Dated advice invites the re-check that resolves it.
    add_note "NOTE — as of session start, this machine's Claude config had drifted from its committed snapshot (${files:-unknown}). Autosave or another session may have captured it since, so re-run the machine-config skill's scripts/backup.sh --check in $repo before acting; if it still reports drift, offer to snapshot and commit so a machine loss doesn't lose the change."
    ;;
  *)
    add_frag "configs: backup BLOCKED"
    add_note "ACTION — backup.sh is refusing to snapshot this machine, so its config is going unrecorded. Reason follows; resolve it before it is forgotten:
$(printf '%s\n' "$out" | head -4)"
    ;;
esac

# Shared-preference drift — the SETTINGS half only. The styles half is no longer reported
# here: zz-machine-config-apply.sh installs styles outright, and it is ordered to run AFTER
# this machine's store sync, which this drop-in is not. Reporting them from here as well
# would announce, from a pre-sync read, work the later drop-in has already done.
#
# Settings stay warn-only. They rewrite settings.json, which is a wider blast radius than an
# unattended session-start hook should take on its own.
#
# Read-only: apply.sh --check writes nothing, and this drop-in still never writes.
aout="$("$here/apply.sh" --check --settings-only 2>&1)"
arc=$?
case "$arc" in
  0) : ;;
  1)
    add_frag "configs: shared prefs to apply"
    add_note "NOTE — as of session start, shared settings from $repo had not been applied here. It is a one-command fix and it writes a backup first; offer to run the machine-config skill's scripts/apply.sh. Re-check before acting, the same way as the snapshot note above."
    ;;
  *)
    add_frag "configs: prefs REFUSED"
    add_note "ACTION — apply.sh is refusing shared settings here, so this machine is not converging and will not start on its own. Reason follows:
$(printf '%s\n' "$aout" | grep REFUSING | head -4)"
    ;;
esac

[ -n "$frag" ] || exit 0
printf '%s\n' "$frag"
[ -n "$notes" ] && printf '%s' "$notes"
exit 0

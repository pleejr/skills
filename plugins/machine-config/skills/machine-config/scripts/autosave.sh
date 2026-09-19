#!/usr/bin/env bash
# autosave.sh — snapshot, commit and push this machine's Claude config, unattended.
# Deterministic; git only; NEVER spawns `claude`. Always exits 0 so it cannot block a hook.
#
# WHY THIS WRITES WHERE session-check.sh ONLY WARNED. The original stance was that a human
# should be present to see the secret scan fail. That was weak: the owner of this setup does
# not read diffs and does not want to run commands, so the "present human" was not adding
# safety — the real choice is between a deterministic fail-closed scan and *no backup at all*.
# A snapshot nobody takes protects nothing.
#
# RESIDUAL RISK, STATED PLAINLY: if the secret pattern in lib.sh has a gap, a credential can
# now be committed AND pushed with nobody watching. Mitigations: the scan runs on the source
# files before anything is copied, so a refusal blocks the whole run; and a refusal is not
# silent — it is surfaced at the next session start by session-check.sh, which reports that
# nothing is being recorded. Widen MC_SECRET_RE rather than working around a refusal.
#
# Bounded and locked because it runs from a lifecycle hook: a hung push must not hold up
# session exit, and two sessions ending together must not race the git index.
#
# Usage: autosave.sh [--no-push]
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

push=1
[ "${1:-}" = "--no-push" ] && push=0

repo="$(mc_repo 2>/dev/null)" || exit 0     # not configured on this machine: nothing to do
[ -d "$repo/.git" ] || exit 0
host="$(mc_host)"

log() { [ -n "${MACHINE_CONFIG_VERBOSE:-}" ] && printf 'autosave: %s\n' "$*"; return 0; }

# One writer at a time; break a lock left by a killed session.
lock="$repo/.git/machine-config-autosave.lock"
if ! mkdir "$lock" 2>/dev/null; then
  [ -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] || exit 0
  rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

# Nothing changed? Do nothing — no empty commits, no pointless pushes.
#
# "Nothing changed" has to mean BOTH that the snapshot matches ~/.claude AND that it is in
# git. Testing only the first is how this reports success while backing up nothing: any run
# that writes the snapshot without committing it — a manual backup.sh, a commit that errored,
# a push that never landed — leaves the files matching ~/.claude forever, so every later run
# early-exits "current" and the snapshot never reaches the remote. That is the mirror of the
# secret-scan failure this header warns about: no backup, wearing a green checkmark.
snapshot_committed() {
  git -C "$repo" diff --quiet HEAD -- "machines/$host" 2>/dev/null &&
    [ -z "$(git -C "$repo" ls-files -o --exclude-standard -- "machines/$host" 2>/dev/null)" ]
}
if "$here/backup.sh" --check >/dev/null 2>&1 && snapshot_committed; then
  log "current"
  exit 0
fi

# backup.sh exits 2 when it REFUSES (credential-shaped content, missing jq). Leave the repo
# untouched and let session-check.sh be the loud channel — a hook has no reader.
out="$("$here/backup.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  log "refused: $out"
  exit 0
fi

# Only ever stage this machine's own snapshot. Someone else's half-edited shared/ change in
# the same working tree is not ours to commit — `git add -A` here would sweep it up.
git -C "$repo" add "machines/$host" >/dev/null 2>&1
git -C "$repo" diff --cached --quiet 2>/dev/null && { log "nothing staged"; exit 0; }

files="$(git -C "$repo" diff --cached --name-only | sed "s|^machines/$host/||" | tr '\n' ' ')"
git -C "$repo" -c user.useConfigOnly=false commit -q \
  -m "chore($host): autosave Claude config — ${files:-snapshot}" \
  -m "Unattended snapshot by the machine-config skill. Secret-scanned before capture." \
  >/dev/null 2>&1 || { log "commit failed"; exit 0; }
log "committed: $files"

[ "$push" -eq 1 ] || exit 0
git -C "$repo" remote get-url origin >/dev/null 2>&1 || exit 0

# Bounded push: no credential prompt can hang a hook, and a watchdog kills a stalled network
# call. Failure is fine — the commit is local, and the next run pushes it.
(
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' \
    git -C "$repo" push --quiet origin HEAD &
  p=$!
  ( sleep "${MACHINE_CONFIG_PUSH_TIMEOUT:-10}"; kill -TERM "$p" 2>/dev/null; sleep 1; kill -KILL "$p" 2>/dev/null ) &
  w=$!
  wait "$p"; kill -TERM "$w" 2>/dev/null; wait "$w"
) >/dev/null 2>&1
log "pushed"
exit 0

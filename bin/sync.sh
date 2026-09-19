#!/usr/bin/env bash
# sync.sh — bring this machine's live skills up to date with the remote, in one step.
# Pulls (rebase, autostashing local WIP) then reconciles symlinks via link.sh —
# which adds new skills, repoints nothing it doesn't own, and prunes links to
# skills that were renamed/removed upstream. Edits to existing skills are already
# live through the symlink, so a pull alone covers those; link.sh handles the
# add/rename/remove cases. Deterministic; never invokes `claude`.
#
# Any arguments are passed through to link.sh — notably `--tags`, so a machine that
# only wants a subset stays scoped on every sync (e.g. a personal laptop):
#
# Usage:
#   bin/sync.sh                 pull, then link every skill
#   bin/sync.sh --tags craft    pull, then link only the matching subset
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Reject a bad invocation before touching the network or the working tree. Previously a
# typo'd flag still pulled and only then failed on link, leaving the repo advanced but the
# symlinks unreconciled — a half-applied sync that exits 1 and looks like it did nothing.
./bin/link.sh --check-args "$@" || exit 1

git pull --rebase --autostash
exec ./bin/link.sh "$@"

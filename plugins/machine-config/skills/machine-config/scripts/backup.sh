#!/usr/bin/env bash
# backup.sh — snapshot THIS machine's Claude Code config into machines/<hostname>/ so a
# replacement machine can be brought back to this exact state. Deterministic; NEVER spawns
# `claude`.
#
# THIS IS THE OTHER HALF OF shared/. Two different jobs, deliberately not the same store:
#   shared/            boundary-free preferences applied to EVERY machine — denylisted,
#                      because config that names a path or grants authority must not travel.
#   machines/<host>/   a full snapshot of ONE machine, restored only onto that machine's
#                      replacement. It therefore MAY carry hooks/statusLine/autoMode — those
#                      are exactly what you need back after losing the laptop, and they are
#                      never applied to a different machine.
#
# WHAT IS DELIBERATELY NOT CAPTURED: conversation and telemetry state (`history.jsonl`,
# `projects/`, `sessions/`, `session-env/`, `telemetry/`, `paste-cache/`, `shell-snapshots/`,
# `backups/`), which is private, large, and not config; and anything that looks like a
# credential — see the scan below. Secrets are recreated by hand on a new machine, per the
# cold-start checklist in the README.
#
# Usage:
#   bin/backup.sh            snapshot into machines/$(hostname -s)/
#   bin/backup.sh --check    report what would change; exit 1 if the snapshot is stale
set -uo pipefail

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
repo="$(mc_repo_or_die)" || exit 2
CFG="$(mc_cfg)"
host="$(mc_host)"
dst="$repo/machines/$host"

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

# Config file list and secret pattern both live in lib.sh so backup and restore agree.

# Fail closed on anything credential-shaped. A snapshot that silently commits a token is
# worse than no snapshot: it is a leak with a green checkmark on it.


staged="$(mktemp -d)"
trap 'rm -rf "$staged"' EXIT

refuse() {
  echo "backup: REFUSING $1 — looks like it contains a credential; keep it out of git" >&2
  echo "        (inspect it, move the value to a chmod-600 file, then re-run)" >&2
  exit 2
}

for f in $MC_FILES; do
  [ -f "$CFG/$f" ] || continue
  grep -aEq "$MC_SECRET_RE" "$CFG/$f" 2>/dev/null && refuse "$f"
  cp "$CFG/$f" "$staged/$f"
done

# Script directories (see MC_DIRS in lib.sh). Every file is scanned individually — these dirs
# live next to credential files, so a wholesale copy without a per-file scan is how a token
# reaches the remote. -type f skips symlinks, which would only encode this machine's paths;
# dotfiles are skipped because that is the shape a dropped secret takes. Modes are preserved
# with cp -p so restored hooks stay executable — a non-executable hook fails at every tool call.
for d in $MC_DIRS; do
  [ -d "$CFG/$d" ] || continue
  while IFS= read -r src; do
    case "$(basename "$src")" in .*) continue ;; esac
    rel="${src#"$CFG"/}"
    grep -aEq "$MC_SECRET_RE" "$src" 2>/dev/null && refuse "$rel"
    mkdir -p "$staged/$(dirname "$rel")"
    cp -p "$src" "$staged/$rel"
  done < <(find "$CFG/$d" -type f 2>/dev/null)
done

# The repo list is what actually makes a new machine usable: what to clone, and from where.
{
  echo "# repos cloned on $host — restore reads this as a clone checklist"
  echo "# repos-dir: ${MC_REPOS_DIR/#"$HOME"/\~}"
  echo "# <dir-name><TAB><remote-url>"
  for d in "$MC_REPOS_DIR"/*/; do
    [ -d "$d/.git" ] || continue
    name="$(basename "$d")"
    url="$(git -C "$d" remote get-url origin 2>/dev/null)" || continue
    [ -n "$url" ] && printf '%s\t%s\n' "$name" "$url"
  done
} > "$staged/repos.txt"

# Record the CLI version WITHOUT executing `claude`. This script is run from a SessionStart
# drop-in, and the engine's session-checks.d contract forbids a drop-in calling `claude` —
# `claude --version` could not recurse (it prints and exits), but the contract is the thing
# that keeps that judgement from having to be re-made correctly every time. The native
# installer symlinks the launcher at a versioned path, so the version is readable.
mc_claude_version > "$staged/claude-version.txt"

# In --check mode, change nothing on disk — not even an empty directory for a machine that
# has never been snapshotted.
[ "$check_only" -eq 1 ] || mkdir -p "$dst"
changed=0
for f in "$staged"/*; do
  b="$(basename "$f")"
  # A staged directory is compared recursively and replaced wholesale, so a file deleted from
  # ~/.claude/bin leaves the snapshot too instead of being resurrected by a later restore.
  if [ -d "$f" ]; then
    if ! diff -rq "$f" "$dst/$b" >/dev/null 2>&1; then
      echo "  ${b}/: $( [ -d "$dst/$b" ] && echo changed || echo new )"
      changed=1
      if [ "$check_only" -eq 0 ]; then rm -rf "${dst:?}/$b"; cp -Rp "$f" "$dst/$b"; fi
    fi
  elif ! diff -q "$f" "$dst/$b" >/dev/null 2>&1; then
    echo "  ${b}: $( [ -f "$dst/$b" ] && echo changed || echo new )"
    changed=1
    [ "$check_only" -eq 0 ] && cp "$f" "$dst/$b"
  fi
done

# A file removed from ~/.claude should leave the snapshot too, or restore resurrects it.
# machine.env is hand-authored config for this machine, NOT a snapshot artifact — pruning
# it here would delete the machine's declaration on every backup.
for f in "$dst"/*; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in machine.env) continue ;; esac
  if [ ! -e "$staged/$b" ]; then
    echo "  ${b}: gone from $CFG"
    changed=1
    [ "$check_only" -eq 0 ] && rm -rf "$f"
  fi
done

if [ "$changed" -eq 0 ]; then
  echo "backup: $host snapshot is current"
  exit 0
fi
if [ "$check_only" -eq 1 ]; then
  echo "backup: snapshot is STALE (run bin/backup.sh, then commit)"
  exit 1
fi
echo "backup: updated machines/$host/ — commit it so it survives losing this machine"

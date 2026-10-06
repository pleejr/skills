#!/usr/bin/env bash
# restore.sh — put a machine's Claude Code config back after losing it. Deterministic;
# NEVER spawns `claude`.
#
# Defaults to restoring THIS hostname's snapshot. `--from <host>` seeds a genuinely new
# machine from an old one — which is the disaster case: the replacement laptop has a new
# name, so there is no snapshot under its own hostname yet.
#
# It restores config and then STOPS at the things a script cannot do (SSH keys, `gh auth`,
# `/login`, MCP re-auth) rather than pretending to finish. Those are printed as a checklist,
# because a restore that silently skips them looks complete and isn't.
#
# Usage:
#   bin/restore.sh                 restore machines/$(hostname -s)/
#   bin/restore.sh --from OldMac   restore another machine's snapshot onto this one
#   bin/restore.sh --dry-run       show what would be written, change nothing
set -uo pipefail

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
repo="$(mc_repo_or_die)" || exit 2
CFG="$(mc_cfg)"
host="$(mc_host)"
src_host="$host"
explicit=0
dry=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from) src_host="${2:-}"; explicit=1; shift 2 ;;
    --from=*) src_host="${1#--from=}"; explicit=1; shift ;;
    --dry-run) dry=1; shift ;;
    *) echo "restore: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# No --from given and this hostname has no snapshot: that IS the disaster case, so infer
# rather than demand a flag nobody remembers. Inference is only safe when unambiguous — with
# several snapshots, picking one silently could restore the wrong machine's config.
if [ "$explicit" -eq 0 ] && [ ! -d "$repo/machines/$src_host" ]; then
  avail="$(find "$repo/machines" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)"
  n="$(printf '%s\n' "$avail" | grep -c .)"
  if [ "$n" -eq 1 ]; then
    src_host="$avail"
    echo "restore: no snapshot for '$(mc_host)'; using the only one available ('$src_host')."
  fi
fi

src="$repo/machines/$src_host"
if [ ! -d "$src" ]; then
  echo "restore: no snapshot for '$src_host'. Available:" >&2
  find "$repo/machines" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort | sed 's/^/  /' >&2
  echo "Pick one with --from <host>." >&2
  exit 1
fi

mkdir -p "$CFG"
echo "restore: $src_host -> $CFG$( [ "$dry" -eq 1 ] && echo ' (dry run)')"

for f in "$src"/*; do
  b="$(basename "$f")"
  case "$b" in repos.txt|claude-version.txt|machine.env) continue ;; esac

  # Script directories (MC_DIRS) are walked file by file rather than replaced wholesale: a
  # restore only ever writes what the snapshot holds and never deletes local files it does not
  # know about. cp -p keeps the executable bit — a hook restored non-executable fails on every
  # tool call, and the settings.json restored alongside would point straight at it.
  if [ -d "$f" ]; then
    while IFS= read -r sf; do
      rel="${sf#"$src"/}"
      if [ -f "$CFG/$rel" ] && ! diff -q "$sf" "$CFG/$rel" >/dev/null 2>&1; then
        echo "  $rel (overwrites existing — backup kept)"
        [ "$dry" -eq 0 ] && cp -p "$CFG/$rel" "$CFG/$rel.bak.$(date +%Y%m%d%H%M%S)"
      elif [ -f "$CFG/$rel" ]; then
        echo "  $rel (identical, skipped)"; continue
      else
        echo "  $rel (new)"
      fi
      if [ "$dry" -eq 0 ]; then
        mkdir -p "$CFG/$(dirname "$rel")"
        cp -p "$sf" "$CFG/$rel"
      fi
    done < <(find "$f" -type f 2>/dev/null)
    continue
  fi

  if [ -f "$CFG/$b" ] && ! diff -q "$f" "$CFG/$b" >/dev/null 2>&1; then
    echo "  $b (overwrites existing — backup kept)"
    [ "$dry" -eq 0 ] && cp "$CFG/$b" "$CFG/$b.bak.$(date +%Y%m%d%H%M%S)"
  elif [ -f "$CFG/$b" ]; then
    echo "  $b (identical, skipped)"; continue
  else
    echo "  $b (new)"
  fi
  [ "$dry" -eq 0 ] && cp "$f" "$CFG/$b"
done

# Paths inside a restored settings.json are absolute and assume $HOME matched. On a machine
# with a different username this is the thing that silently breaks, so say so rather than
# leaving hooks that point nowhere.
if [ -f "$CFG/settings.json" ] && grep -Eq '"/(Users|home)/' "$CFG/settings.json" 2>/dev/null; then
  bad="$(grep -oE '"/(Users|home)/[^/]*' "$CFG/settings.json" | sort -u | sed 's/"//' | grep -v "^$HOME$" | head -3)"
  [ -n "$bad" ] && echo "restore: WARNING — settings.json references other home dirs ($bad); fix those paths."
fi

# A snapshot can carry a `directory` marketplace — the old machine's working tree. Restored as
# is, the new machine would load plugins from a path its clone list has not even created yet,
# and afterwards from whatever that checkout happens to hold. Point it at its remote instead;
# on a dry run, show the rewrite against the snapshot's copy without writing it.
echo
if [ "$dry" -eq 1 ]; then
  CLAUDE_CONFIG_DIR="$src" "$here/remote-marketplaces.sh" --repos "$src/repos.txt" --dry-run
else
  "$here/remote-marketplaces.sh" --repos "$src/repos.txt"
fi

echo
echo "Clone list from $src_host:"
if [ -f "$src/repos.txt" ]; then
  # The snapshot records the old machine's clone dir ($HOME written as ~); fall back to this
  # machine's MC_REPOS_DIR for snapshots taken before that header existed.
  rdir="$(sed -n 's/^# repos-dir: //p' "$src/repos.txt" | head -1)"
  awk -F'\t' -v dir="${rdir:-${MC_REPOS_DIR/#"$HOME"/\~}}" '!/^#/ && NF==2 {printf "  git clone %s %s/%s\n", $2, dir, $1}' "$src/repos.txt"
else
  echo "  (none recorded)"
fi

# Copying the right bytes is not the same as restoring the behavior. verify.sh asks the wired
# components whether they actually work — see the failure it exists for at the top of that
# file. Skipped on a dry run, which has written nothing to check. Its exit code is deliberately
# NOT this script's: a degraded component is a to-do item, not a failed restore, and the manual
# checklist below still has to print.
if [ "$dry" -eq 0 ] && [ -x "$here/verify.sh" ]; then
  echo
  "$here/verify.sh" || true
fi

cat <<'EOF'

Still manual — a script cannot do these, and the restore is not done until they are:
  1. SSH key: generate, add to GitHub (git remotes above need it)
  2. gh auth login
  3. Install the claude CLI via the native installer (not Homebrew — it self-updates)
  4. claude  ->  /login
  5. Re-auth any MCP servers
  6. Recreate secret files (chmod 600) — never restored from git by design
  7. git submodule update --init --recursive  in any clone that carries submodules
EOF

#!/usr/bin/env bash
# init.sh — create a config repo and point this machine at it. Run once per boundary.
#
# The repo holds DATA only; the machinery is this skill. That split is what lets two
# boundaries (personal / work) keep separate private repos while running one implementation.
#
# Usage: scripts/init.sh /path/to/config-repo
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

dest="${1:-}"
[ -n "$dest" ] || { echo "usage: init.sh /path/to/config-repo" >&2; exit 2; }
case "$dest" in "~/"*) dest="$HOME/${dest#\~/}" ;; esac

CFG="$(mc_cfg)"; host="$(mc_host)"
mkdir -p "$dest/shared" "$dest/machines/$host" || exit 2

[ -d "$dest/.git" ] || { git -C "$dest" init -q && echo "init: git repo created at $dest"; }

if [ ! -f "$dest/shared/settings.shared.json" ]; then
  # Start EMPTY. Seeding this from the current machine is how path- and authority-bearing
  # keys end up shared with every other machine; shared/ is opt-in, key by key.
  printf '{}\n' > "$dest/shared/settings.shared.json"
  echo "init: shared/settings.shared.json (empty — add invariant prefs deliberately)"
fi

if [ ! -f "$dest/machines/$host/machine.env" ]; then
  printf '# %s\n' "$host" > "$dest/machines/$host/machine.env"
  echo "init: machines/$host/machine.env"
fi

if [ ! -f "$dest/.gitignore" ]; then
  printf '*.local\n*.bak\n*.bak.*\n' > "$dest/.gitignore"
fi

printf '%s\n' "$dest" > "$CFG/machine-config-repo"
echo "init: this machine now points at $dest ($CFG/machine-config-repo)"
echo
echo "Next:"
echo "  $here/backup.sh          # snapshot this machine"
echo "  git -C $dest add -A && git -C $dest commit -m 'initial snapshot'"
echo "  $here/install.sh         # wire autosave + the session-start drift check"

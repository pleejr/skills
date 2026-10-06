#!/usr/bin/env bash
# test-autosave.sh — autosave's push must survive the SessionEnd hook being cancelled.
# Claude Code aborts a SessionEnd hook when the session is torn down; before the push was
# detached, the commit landed and the push died with the hook, so snapshots never left the
# machine. This runs autosave against a slow local remote, kills its whole process group
# 1.5s in, and requires the commit to reach the remote anyway.
#
# Usage: test-autosave.sh [path/to/autosave.sh]   (default: the one beside this file)
set -u
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
subject="${1:-$here/autosave.sh}"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/cfg" MACHINE_CONFIG_REPO="$T/repo" MACHINE_CONFIG_HOST=box
mkdir -p "$T/cfg"; echo '{"a":1}' > "$T/cfg/settings.json"
git init -q --bare "$T/remote.git"
printf '#!/bin/sh\nsleep 3\n' > "$T/remote.git/hooks/pre-receive"; chmod +x "$T/remote.git/hooks/pre-receive"
git init -q -b main "$T/repo"
git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$T/repo" remote add origin "$T/remote.git"
git -C "$T/repo" push -q -u origin main 2>/dev/null

perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash "$subject" & pid=$!
sleep 1.5
kill -TERM -- "-$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

for _ in $(seq 20); do
  [ "$(git -C "$T/repo" rev-parse HEAD)" = "$(git -C "$T/remote.git" rev-parse main)" ] && break
  sleep 0.5
done
if [ "$(git -C "$T/repo" rev-list --count HEAD)" -lt 2 ]; then
  echo "FAIL: autosave made no commit"; exit 1
fi
if [ "$(git -C "$T/repo" rev-parse HEAD)" != "$(git -C "$T/remote.git" rev-parse main)" ]; then
  echo "FAIL: commit landed but the push died with the cancelled hook"; exit 1
fi
echo "PASS: push survived hook cancellation"

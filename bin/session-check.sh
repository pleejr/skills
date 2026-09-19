#!/usr/bin/env bash
# session-check.sh — a wiki-engine `session-checks.d` drop-in for the pleejr/skills install.
# Installed into ~/.claude/session-checks.d/ by bin/link.sh (as a SYMLINK, so an edit here is
# live on the next session with no reinstall). The engine's session-preflight runs it and folds
# the output into the one SessionStart banner. Contract: first stdout line = compact banner
# fragment (empty = nothing to report), remaining lines = action/notes for the assistant.
# NEVER calls `claude` (hard rule: no claude in a hook — the fork-bomb trap). Always exits 0.
#
# WHAT IT DOES: brings this machine's skills up to date automatically, every session, instead
# of nagging on a timer. It replaces the old `.wiki-catchup` age check, which was a proxy that
# was wrong in both directions — it fired when nothing had landed upstream, and stayed quiet
# when five skills merged the day after a sync.
#
# WHY IT IS NOT JUST `sync.sh`: sync.sh is `git pull --rebase --autostash` + link.sh, which is
# right when a HUMAN runs it and can see the result. Unattended, autostash is the sharp edge —
# it would stash a half-written skill, and if the rebase then conflicted the WIP would be left
# in the stash with the explanation printed somewhere the user never sees (hook stdout goes to
# the model, not the human). So this path is deliberately narrower and refuses rather than
# repairs:
#   - syncs only on the default branch, with a clean tree and no merge/rebase in flight;
#   - fast-forward ONLY, never a rebase or a merge commit — divergence is reported, not solved;
#   - bounded fetch, because the engine runs drop-ins synchronously with NO timeout of its own,
#     so an unreachable remote here would hang session start;
#   - locked, so two sessions booting together cannot race on the git index;
#   - silent when there is nothing to say (offline included — no nagging on a plane).
# Anything it refuses is reported for the human to resolve with /sync-skills.
set -uo pipefail

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FETCH_TIMEOUT="${SKILLS_SYNC_TIMEOUT:-6}"          # seconds allowed for the network fetch
MIN_INTERVAL="${SKILLS_SYNC_MIN_INTERVAL_MIN:-10}" # minutes; skip refetch on rapid resumes

# First run: no chosen skill set. Never auto-install a subset the user hasn't picked.
if [ ! -f "$CFG/skill-tags" ]; then
  echo "skills: first run — /sync-skills"
  echo "ACTION — first run on this machine: no skill set chosen. Ask the user to run /sync-skills to pick which skills to install (remembered thereafter)."
  exit 0
fi

# Resolve the repo from this script's real path (installed as a symlink; no `readlink -f`,
# which is not portable to stock macOS).
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)" || exit 0
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
repo="$(cd -P "$(dirname "$src")/.." && pwd)" || exit 0
[ -d "$repo/.git" ] || exit 0

git_q() { git -C "$repo" "$@" 2>/dev/null; }

# --- refuse rather than repair -------------------------------------------------------------
# An in-flight merge/rebase means a human is mid-something; touching it would be hostile.
for f in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD BISECT_LOG; do
  if [ -e "$repo/.git/$f" ]; then
    echo "skills: repo mid-operation — sync skipped"
    echo "NOTE — skills repo has an unfinished merge/rebase/bisect ($f present); auto-sync skipped. Mention it only if the user asks about skills."
    exit 0
  fi
done

branch="$(git_q rev-parse --abbrev-ref HEAD)"
default_branch="$(git_q symbolic-ref --short refs/remotes/origin/HEAD)"; default_branch="${default_branch#origin/}"
[ -n "$default_branch" ] || default_branch="main"
if [ "$branch" != "$default_branch" ]; then
  echo "skills: on branch $branch — sync skipped"
  echo "NOTE — skills repo is on '$branch', not '$default_branch'; auto-sync skipped so in-progress work is untouched."
  exit 0
fi

# Uncommitted work: a hook must never stash someone's WIP.
if [ -n "$(git_q status --porcelain)" ]; then
  echo "skills: local changes — sync skipped"
  echo "ACTION — skills repo has uncommitted changes, so auto-sync was skipped (a hook must never stash WIP). If the user wants those changes shipped, offer to commit + PR them; otherwise /sync-skills once they settle."
  exit 0
fi

# One syncer at a time: two sessions booting together would otherwise race the git index.
lock="$repo/.git/skills-autosync.lock"
if ! mkdir "$lock" 2>/dev/null; then
  # Break a lock left behind by a killed session (older than 5 minutes), else defer quietly.
  if [ -z "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then exit 0; fi
  rmdir "$lock" 2>/dev/null || true
  mkdir "$lock" 2>/dev/null || exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

# --- bounded fetch -------------------------------------------------------------------------
# Rate-limit: on a rapid resume cycle a refetch buys nothing and costs latency every time.
if [ -f "$repo/.git/FETCH_HEAD" ] && [ -z "$(find "$repo/.git/FETCH_HEAD" -mmin +"$MIN_INTERVAL" 2>/dev/null)" ]; then
  skip_fetch=1
else
  skip_fetch=0
fi

if [ "$skip_fetch" -eq 0 ]; then
  # The engine runs this drop-in synchronously and does not bound it, so bound it here: a
  # watchdog kills a fetch that outlives the budget. GIT_TERMINAL_PROMPT=0 + ssh BatchMode
  # because a credential or host-key prompt would hang forever with nobody to answer it.
  # The whole thing sits in a redirected subshell so the shell's "Terminated" job notice
  # cannot leak into the banner contract on stdout.
  (
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' \
      git -C "$repo" fetch --quiet origin "$default_branch" &
    fpid=$!
    ( sleep "$FETCH_TIMEOUT"; kill -TERM "$fpid" 2>/dev/null; sleep 1; kill -KILL "$fpid" 2>/dev/null ) &
    wpid=$!
    wait "$fpid"                      # offline / unreachable: fall through and stay silent
    kill -TERM "$wpid" 2>/dev/null
    wait "$wpid"
  ) >/dev/null 2>&1
fi

# --- compare and fast-forward --------------------------------------------------------------
counts="$(git_q rev-list --left-right --count "HEAD...origin/$default_branch")" || exit 0
ahead="$(printf '%s' "$counts" | awk '{print $1}')"
behind="$(printf '%s' "$counts" | awk '{print $2}')"
case "${behind:-}" in ''|*[!0-9]*) exit 0 ;; esac
case "${ahead:-}" in ''|*[!0-9]*) ahead=0 ;; esac

[ "$behind" -eq 0 ] && exit 0             # current — say nothing

if [ "$ahead" -gt 0 ]; then               # diverged: report, never auto-resolve
  echo "skills: $behind behind / $ahead ahead — /sync-skills"
  echo "ACTION — skills repo has diverged from origin/$default_branch ($behind behind, $ahead ahead). Auto-sync only fast-forwards, so this needs a human call: offer to push the local commits or rebase them."
  exit 0
fi

before="$(git_q rev-parse HEAD)"
if ! git_q merge --ff-only "origin/$default_branch" >/dev/null; then
  echo "skills: fast-forward failed — /sync-skills"
  echo "ACTION — skills repo is $behind behind but the fast-forward failed. Suggest the user run bin/sync.sh manually and report the error."
  exit 0
fi

# Reconcile symlinks: edits to existing skills are already live through the symlink, but
# added / renamed / removed skills need link.sh, scoped to this machine's chosen tags.
tags="$(tr -d '[:space:]' < "$CFG/skill-tags" 2>/dev/null)"
if [ -n "$tags" ]; then
  link_out="$("$repo/bin/link.sh" --tags "$tags" 2>&1)"
else
  link_out="$("$repo/bin/link.sh" 2>&1)"
fi
changed="$(printf '%s\n' "$link_out" | grep -cE '^(link|prune|relink)  *' || true)"

# Name the skills whose files actually moved, so the assistant can say what is new.
touched="$(git_q diff --name-only "$before" HEAD -- skills/ | awk -F/ 'NF>1 {print $2}' | sort -u | tr '\n' ' ')"

echo "skills: synced (+$behind)"
echo "NOTE — skills auto-synced $behind commit(s) from origin/$default_branch; ${changed:-0} symlink change(s).${touched:+ Skills touched: $touched}"
if [ "${changed:-0}" -gt 0 ]; then
  echo "A newly added or renamed skill only appears in THIS session's skill list if it was linked before session start; if the user asks for one that seems missing, a restart picks it up."
fi
exit 0

#!/usr/bin/env bash
# Merge a PR and clean up, from anywhere — including from inside a linked worktree,
# which is where `gh pr merge --delete-branch` breaks.
#
# The failure this exists to prevent: with the branch checked out in a linked worktree
# and `main` held by the primary checkout, `gh pr merge --admin --delete-branch` merges
# the PR server-side and THEN tries to switch the worktree to the default branch, which
# git refuses -- `fatal: 'main' is already used by worktree at ...`. That error is
# printed by gh's local post-merge step, long after the merge succeeded, so it reads as
# a failed merge when the merge is done. Worse, gh aborts before deleting the branch, so
# the remote ref survives a run that reported `--delete-branch`; a later worktree of the
# same name is then rejected non-fast-forward against a branch believed deleted twice.
#
# So: merge with --repo and WITHOUT --delete-branch (no local git operations at all),
# verify MERGED from the API rather than from an exit code, then do every local step
# explicitly and idempotently. Re-running after a partial failure is safe and is the
# intended recovery -- each step checks the state it is about to create.
#
# A bare number is resolved against the repo the cwd belongs to. Run from the wrong
# directory, `pr-merge.sh 535` is PR 535 of whatever repo you happen to be standing in,
# so when a number is given pass --repo as well; without it the script refuses a PR whose
# head branch is not on the cwd repo's origin and whose head repo is not the cwd repo.
#
# Checks are waited for before the merge, because --admin bypasses branch protection and
# so nothing else stops a merge while CI is still running. See wait_for_checks below.
#
# Usage:
#   bin/pr-merge.sh                     # PR of the current branch, squash, --admin
#   bin/pr-merge.sh 27                  # by number, in the repo the cwd belongs to
#   bin/pr-merge.sh --repo o/r 27       # by number, in a named repo (cwd irrelevant)
#   bin/pr-merge.sh --dry-run           # print the plan, touch nothing
#   bin/pr-merge.sh --strategy rebase --no-admin --keep-worktree
#   bin/pr-merge.sh --skip-checks 27    # merge without waiting for or reading checks
# Env: PR_MERGE_REGISTER_TIMEOUT (default 180s), PR_MERGE_CHECKS_TIMEOUT (default 1800s)
set -euo pipefail

STRATEGY=squash
ADMIN=--admin
KEEP_WORKTREE=0
DRY=0
SKIP_CHECKS=0
PR=""
REPO=""
REGISTER_TIMEOUT=${PR_MERGE_REGISTER_TIMEOUT:-180}
CHECKS_TIMEOUT=${PR_MERGE_CHECKS_TIMEOUT:-1800}

die() { printf 'pr-merge: %s\n' "$*" >&2; exit 1; }
say() { printf 'pr-merge: %s\n' "$*"; }
run() { if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --strategy) STRATEGY="${2:-}"; shift 2 ;;
    --no-admin) ADMIN=""; shift ;;
    --keep-worktree) KEEP_WORKTREE=1; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --skip-checks) SKIP_CHECKS=1; shift ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) PR="$1"; shift ;;
  esac
done
case "$STRATEGY" in squash|merge|rebase) ;; *) die "--strategy must be squash|merge|rebase" ;; esac
case "$REPO" in "") ;; */*) ;; *) die "--repo must be owner/name, got: $REPO" ;; esac
[ -n "$REPO" ] && [ -z "$PR" ] && die "--repo needs a PR number; the current-branch lookup is cwd-only"

command -v gh  >/dev/null 2>&1 || die "gh not found"
command -v git >/dev/null 2>&1 || die "git not found"
command -v jq  >/dev/null 2>&1 || die "jq not found"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# The repo is the cwd's unless --repo names one. With --repo, the cwd is consulted only
# to decide whether local cleanup applies: it does when the cwd belongs to that same
# repo, and is skipped otherwise -- a `push origin --delete` aimed at a same-named branch
# in an unrelated checkout is exactly the wrong-cwd damage this flag exists to prevent.
LOCAL=1
CWD_SLUG=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  CWD_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
fi
if [ -n "$REPO" ]; then
  SLUG=$REPO
  [ "$(lower "$CWD_SLUG")" = "$(lower "$SLUG")" ] || LOCAL=0
else
  [ -n "$CWD_SLUG" ] || die "not inside a git repository with a GitHub remote; pass --repo owner/name"
  SLUG=$CWD_SLUG
fi

# The primary checkout is the first entry of `worktree list`; every local step runs
# against it with `git -C`, never a `cd` -- both because the PreToolUse worktree gate
# reads the command's stated path rather than the shell's cwd, and because this script
# is routinely invoked from a worktree that it is about to delete.
PRIMARY=""
if [ "$LOCAL" = 1 ]; then
  PRIMARY=$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')
  [ -n "$PRIMARY" ] || die "could not resolve the primary checkout"
fi

# Resolve the PR from the current branch when no number is given. Do this BEFORE any
# mutation: after cleanup the branch is gone and the same lookup would fail.
FIELDS=number,state,headRefName,baseRefName,headRefOid,url,title,headRepository,headRepositoryOwner
if [ -n "$PR" ]; then
  HINT=""
  [ -z "$REPO" ] && HINT=" (resolved from the cwd) — if you meant another repo, pass --repo owner/name"
  META=$(gh pr view "$PR" --repo "$SLUG" --json "$FIELDS") || die "no PR $PR in $SLUG$HINT"
else
  META=$(gh pr view --json "$FIELDS" 2>/dev/null) || die "no PR for the current branch; pass a number"
fi
NUM=$(jq -r .number <<<"$META")
STATE=$(jq -r .state <<<"$META")
HEAD=$(jq -r .headRefName <<<"$META")
BASE=$(jq -r .baseRefName <<<"$META")
HEADSHA=$(jq -r .headRefOid <<<"$META")
TITLE=$(jq -r .title <<<"$META")
HEAD_SLUG=$(jq -r '"\(.headRepositoryOwner.login // "")/\(.headRepository.name // "")"' <<<"$META")

# cwd guard: a bare number was resolved against the cwd's repo, so demand evidence that
# the PR belongs here -- its head branch is on this checkout's origin, or its head repo
# is this repo. Runs under --dry-run too; the refusal is the point of the dry run.
if [ -z "$REPO" ] && [ -n "$PR" ]; then
  if ! git ls-remote --exit-code --heads origin "$HEAD" >/dev/null 2>&1 \
     && [ "$(lower "$HEAD_SLUG")" != "$(lower "$SLUG")" ]; then
    die "refusing $SLUG#$NUM \"$TITLE\": head $HEAD_SLUG:$HEAD is not in the cwd repo $SLUG — pass --repo owner/name to name the repo you meant"
  fi
fi

say "$SLUG#$NUM [$STATE] $HEAD -> $BASE"
say "$TITLE"
[ "$DRY" = 1 ] && say "dry run — nothing will be changed"
[ "$LOCAL" = 0 ] && say "cwd is ${CWD_SLUG:-not a GitHub checkout}, not $SLUG — merging via the API only, no local cleanup"

# The PR's check buckets (pass, fail, pending, skipping, cancel), one per line. gh exits
# nonzero with "no checks reported" when none have registered, which is read as empty.
check_buckets() {
  gh pr checks "$NUM" --repo "$SLUG" --json name,bucket \
    -q '.[] | "\(.bucket)\t\(.name)"' 2>/dev/null || true
}

# Wait for the PR's checks to register and finish, then refuse on any failure.
#
# The failure this exists to prevent: right after a push, `gh pr checks --watch` prints
# "no checks reported" and returns at once, because the workflows have not registered
# yet -- not because the repo has none. Callers ran it, saw it return, and this script
# merged with --admin while the run was still pending, five times between 2026-09-29 and
# 2026-10-19. A note telling the caller to wait did not stop it, so the wait lives here.
#
# Registration is staggered (a GitHub Actions run and an external status such as a
# Terraform Cloud plan arrive seconds apart), so after the first check appears the gate
# waits a short settle period and re-reads before watching, and it re-reads once more
# after everything finishes in case a late check registered meanwhile.
wait_for_checks() {
  local buckets waited=0 active
  buckets=$(check_buckets)
  if [ "$DRY" = 1 ]; then
    say "checks now: ${buckets:-none registered} — a real run waits for them"
    return 0
  fi
  while [ -z "$buckets" ] && [ "$waited" -lt "$REGISTER_TIMEOUT" ]; do
    [ "$waited" = 0 ] && say "waiting up to ${REGISTER_TIMEOUT}s for checks to register on $HEADSHA"
    sleep 5; waited=$((waited + 5))
    buckets=$(check_buckets)
  done
  if [ -z "$buckets" ]; then
    # Nothing registered. That is only "no CI" when the repo has no active workflow;
    # with one, it is a run that has not shown up yet, and merging is the old bug.
    active=$(gh api "repos/$SLUG/actions/workflows" \
             -q '[.workflows[] | select(.state == "active")] | length' 2>/dev/null || echo unknown)
    if [ "$active" = 0 ]; then
      say "no checks registered and $SLUG has no active workflows — merging without checks"
      return 0
    fi
    die "no checks registered on #$NUM after ${REGISTER_TIMEOUT}s ($active active workflows in $SLUG) — re-run, or pass --skip-checks if the PR runs none"
  fi
  sleep 15
  local pass
  for pass in 1 2; do
    waited=0
    while buckets=$(check_buckets); grep -q '^pending' <<<"$buckets"; do
      [ "$waited" -ge "$CHECKS_TIMEOUT" ] && die "checks still pending on #$NUM after ${CHECKS_TIMEOUT}s: $(grep '^pending' <<<"$buckets" | cut -f2 | paste -sd, -)"
      [ "$waited" = 0 ] && say "waiting for $(grep -c '^pending' <<<"$buckets") pending check(s)"
      sleep 10; waited=$((waited + 10))
    done
    [ "$pass" = 1 ] && sleep 10
  done
  if grep -qE '^(fail|cancel)' <<<"$buckets"; then
    die "refusing to merge #$NUM — failed checks: $(grep -E '^(fail|cancel)' <<<"$buckets" | cut -f2 | paste -sd, -)"
  fi
  say "checks green: $(wc -l <<<"$buckets" | tr -d ' ') registered, none failed"
}

case "$STATE" in
  OPEN)
    if [ "$SKIP_CHECKS" = 1 ]; then
      say "--skip-checks — merging without reading checks"
    else
      wait_for_checks
    fi
    # --repo keeps gh entirely on the API: no local checkout, no branch switch, nothing
    # to collide with the worktree. --delete-branch is deliberately NOT passed; the
    # remote ref is deleted below, after the merge is confirmed rather than assumed.
    run gh pr merge "$NUM" --repo "$SLUG" "--$STRATEGY" ${ADMIN:+$ADMIN}
    ;;
  MERGED) say "already merged — continuing to cleanup (this script is idempotent)" ;;
  CLOSED) die "PR #$NUM is CLOSED, not merged — refusing to clean up its branch" ;;
  *)      die "unexpected PR state: $STATE" ;;
esac

# Confirm from the API. gh's exit code covers the request, not the outcome, and the
# whole point of this script is that a nonzero exit has meant "merged fine" before.
if [ "$DRY" = 0 ]; then
  for _ in 1 2 3 4 5; do
    STATE=$(gh pr view "$NUM" --repo "$SLUG" --json state -q .state)
    [ "$STATE" = MERGED ] && break
    sleep 2
  done
  [ "$STATE" = MERGED ] || die "PR #$NUM is $STATE, not MERGED — stopping before cleanup"
  say "confirmed MERGED"
fi

# API-only path: no checkout of $SLUG here, so the remote head branch is deleted through
# the API rather than through a local remote. Only a same-repo head is touched; a fork's
# branch is not ours to delete. A failed delete is a warning, not an error: the merge
# itself is already confirmed above.
if [ "$LOCAL" = 0 ]; then
  if [ "$(lower "$HEAD_SLUG")" != "$(lower "$SLUG")" ]; then
    say "head $HEAD_SLUG:$HEAD is a fork — leaving its branch alone"
  elif ! gh api "repos/$SLUG/git/ref/heads/$HEAD" >/dev/null 2>&1; then
    say "remote branch $HEAD already gone"
  elif run gh api -X DELETE "repos/$SLUG/git/refs/heads/$HEAD" >/dev/null; then
    say "deleted remote branch $HEAD"
  else
    say "WARNING: could not delete remote branch $HEAD — re-run, or: gh api -X DELETE repos/$SLUG/git/refs/heads/$HEAD"
  fi
  say "done — $(jq -r .url <<<"$META")"
  exit 0
fi

# --- local cleanup, each step guarded by the state it expects -------------------------

# The merge is done by now, so a network failure from here on must not abort the run:
# under `set -e` a failed fetch (a GitHub SSH blip answering `Permission denied
# (publickey)`) used to exit before the worktree and branch cleanup, leaving both behind
# with nothing said. Only the remote delete and the fast-forward need the network; the
# rest is local and still runs. Every skipped step is named in the output.
OFFLINE=0
if ! run git -C "$PRIMARY" fetch origin --prune --quiet; then
  OFFLINE=1
  say "WARNING: fetch failed after the merge — skipping the remote-branch delete and the fast-forward"
fi

if [ "$OFFLINE" = 1 ]; then
  say "remote branch $HEAD not checked — re-run to delete it, or: git -C $PRIMARY push origin --delete $HEAD"
elif git -C "$PRIMARY" ls-remote --exit-code --heads origin "$HEAD" >/dev/null 2>&1; then
  if run git -C "$PRIMARY" push origin --delete "$HEAD"; then
    say "deleted remote branch $HEAD"
  else
    say "WARNING: could not delete remote branch $HEAD — delete it by hand"
  fi
else
  say "remote branch $HEAD already gone"
fi

# Retire the worktree holding the merged branch, if any. Refuse on anything unexpected:
# a dirty tree, or a local tip that is not what was merged (commits pushed after the
# merge, or a branch reused for something else). Leaving a worktree in place costs a
# manual cleanup; removing one with unmerged work costs the work.
#
# The primary checkout is excluded deliberately: it appears in `worktree list` like any
# other entry, but `git worktree remove` always refuses the main working tree. Matching it
# here aborted the script under `set -e` AFTER the merge and the remote-branch deletion,
# and re-running wedged on the same line -- so the idempotent recovery this script
# promises did not hold for the plainest case of all, a single clone with the merged
# branch checked out. A primary checkout sitting on the branch is reported below instead.
WT=$(git -C "$PRIMARY" worktree list --porcelain \
     | awk -v b="branch refs/heads/$HEAD" '/^worktree /{p=substr($0,10)} $0==b{print p; exit}')
if [ "$WT" = "$PRIMARY" ]; then WT=""; fi
if [ -n "$WT" ] && [ "$KEEP_WORKTREE" = 0 ]; then
  if [ -n "$(git -C "$WT" status --porcelain)" ]; then
    say "KEEPING worktree $WT — uncommitted changes present"
  elif [ "$(git -C "$WT" rev-parse HEAD)" != "$HEADSHA" ]; then
    say "KEEPING worktree $WT — local tip is not the merged commit ($HEADSHA)"
  else
    # `git worktree remove` refuses outright when the worktree contains an initialised
    # submodule -- "fatal: working trees containing submodules cannot be moved or
    # removed" -- and under `set -e` that aborted the script AFTER the merge and the
    # remote-branch deletion. Same shape as the primary-checkout case above: the
    # cleanup this script promises did not hold, and it left the worktree and the local
    # branch behind for a hand sweep. Hit on 2026-08-13 in a vault whose engine is a
    # pinned submodule; initialising it inside a worktree is ordinary, so this is not
    # an exotic input.
    #
    # --force is reachable HERE and only here, as a retry rather than the first
    # attempt. The two guards above have already established that the tree is clean and
    # sitting on the merged commit, so the work --force would otherwise endanger has
    # been shown not to exist -- and keeping the plain attempt first means an
    # unexpected refusal still surfaces its own stderr instead of being forced past.
    if run git -C "$PRIMARY" worktree remove "$WT" 2>/dev/null; then
      say "removed worktree $WT"
      WT=""
    elif run git -C "$PRIMARY" worktree remove --force "$WT"; then
      say "removed worktree $WT (--force; it contained an initialised submodule)"
      WT=""
    else
      # Never abort here. Everything irreversible already happened, and a stranded
      # worktree costs a manual cleanup the operator can see, whereas a non-zero exit
      # at this point reads as a failed merge that in fact succeeded.
      say "KEEPING worktree $WT — git refused to remove it; remove it by hand:"
      say "  git -C $PRIMARY worktree remove --force $WT"
    fi
  fi
elif [ -n "$WT" ]; then
  say "keeping worktree $WT (--keep-worktree)"
fi

CUR=$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)

# git refuses to delete a branch that is checked out anywhere, so every keep-case below
# is a case the delete would have failed on. The primary checkout is named separately
# because moving it is not this script's call -- see the fast-forward guard below.
if git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$HEAD"; then
  if [ "$CUR" = "$HEAD" ]; then
    say "kept local branch $HEAD — checked out in the primary checkout $PRIMARY"
    say "  switch it away and re-run to finish cleanup: git -C $PRIMARY switch $BASE"
  elif [ -z "$WT" ] || [ "$DRY" = 1 ]; then
    run git -C "$PRIMARY" branch -D "$HEAD"
    say "deleted local branch $HEAD"
  else
    say "kept local branch $HEAD — still checked out in $WT"
  fi
fi

# Fast-forward the primary checkout only when it is sitting on the base branch and
# clean. Anything else is someone else's working state, not this script's to move.
if [ "$OFFLINE" = 1 ]; then
  say "primary checkout not fast-forwarded (fetch failed) — run: git -C $PRIMARY pull --ff-only"
elif [ "$CUR" != "$BASE" ]; then
  say "primary checkout is on $CUR, not $BASE — left alone (fetched, so origin/$BASE is current)"
elif [ -n "$(git -C "$PRIMARY" status --porcelain)" ]; then
  say "primary checkout is dirty — left alone; run: git -C $PRIMARY merge --ff-only origin/$BASE"
else
  run git -C "$PRIMARY" merge --ff-only "origin/$BASE" --quiet
  say "fast-forwarded $PRIMARY to origin/$BASE"
fi

if [ "$OFFLINE" = 1 ]; then
  say "done with warnings — merged, local cleanup finished, network steps skipped — $(jq -r .url <<<"$META")"
else
  say "done — $(jq -r .url <<<"$META")"
fi

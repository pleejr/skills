# audit-the-instrument — the incidents behind the rules

Full narratives for the one-clause incidents in `SKILL.md`. Each is a wrong answer that was held confidently; several were acted on. Most also exist as lesson notes in the consuming vault's `memory/`.

## §1 Did the harness run at all?

- **Tools the harness depends on.** A job reported all six of its tests `*** HUNG *** exit=137` at an identical ~20 seconds. Exit 137 is SIGKILL, and both `timeout` and `gtimeout` were absent from the host, so the harness killed everything unconditionally. Identical exit codes at identical durations across structurally different tests describe the harness, not the system.
- **Hand-firing is not the wiring.** A session-capture hook was recorded verified end to end because its exact command, fired manually with a hook-shaped payload, exited 0. The real hook had never once succeeded from the usual working directory: the host aborts that hook type after about a second when no explicit `timeout` is set, and the script needed 3.14 seconds there.
- **Identity and parameters.** Two "successful" runs of an SSH diagnostic used a throwaway test credential, so the production credential was never exercised.

## §2 Did the input parse the way it reads?

- `ssh -G` and `ssh -v` resolve hashed, bracketed and negated forms a literal grep misses — a grep of a hostname against a hashed `known_hosts` produced a "missing entry" root cause while the same job's `ssh -v` log said the host key was known.
- `--terms "a b c d e"` on a comma-separated flag collapsed into one term, matched nothing, and returned `FRESH — no prior work matched` while an open ticket sat in the active sprint. The named verdict was more dangerous than `[]` would have been: `[]` invites "did I ask that right?", `FRESH (content layer only)` looks like a judgement the tool reached.

## §3 What population did it cover?

- **Which refs.** An audit of every caller of a changed module read `origin/main` in each consuming repo and concluded "zero exposure". `main` was never the population at risk — an open pull request, cut before the pinning commit, still carried the old constraint and failed hours later.
- **Which copy.** The first pass of that same audit read local working copies up to four commits behind and reported three call sites as primed to fail. Pure fiction, caught only because it contradicted merges verified minutes earlier.
- **Denominator.** A sweep of 13 workspaces for errored runs returned zero — but only 5 had run since the change. "0 of 13" and "0 of 5 that ran" are different findings.
- **Wrong index.** Paging a workspace-wide channel enumeration to 113 results found no match, reported as "the bot cannot see the channel". The channel was private, the bot was already a member, and the call asking a principal for *its own* memberships returned it immediately from a list of 11.
- **API population traps.** A metric queried on one dimension returns `0 datapoints` when it is published under two; a metrics call capped at 1440 datapoints returns empty when the period is too small for the window.

## §4 When did it run, and against which tree?

- **Timing.** A session-start check ran before the drop-in that syncs the store it watches, read the pre-sync state, and reported clean while an update sat on disk unread for the whole session. Not broken, misconfigured, or disabled — **early** — and it fires correctly for every drift predating the sync, so it has a history of working that says nothing about the case it cannot see. Glob order was the only thing declaring the producer/consumer edge; a prefix forcing the probe last is load-bearing, and a rename re-opens the bug silently.
- **Tree.** A maintenance step aimed at an isolated worktree went looking for a file that is deliberately untracked — so it cannot exist in a worktree at all — found nothing, and reported success for nine consecutive releases. The absence was structural. A branch cut from a stale ref answers a search for existing work with the same silence, and *"nobody has written this yet"* is an ordinary thing to be true.
- **Reproducing the timing.** Re-running a blind probe faithfully reproduces its blindness — it passes again for the same reason, and the second pass reads as confirmation.

## §5 Can the result discriminate?

- **Degenerate negative.** Probing a vendor entitlement endpoint, two known abilities returned `204` (positive control passed); the ability under test returned `404` across four spellings, read as "not licensed". A deliberately invented ability name returned the *same* `404`: the endpoint answers `404` for "no such ability" and does not model that feature at all.
- **Working fallback.** Ten consecutive end-to-end database probes all succeeded while two resolvers disagreed about the endpoint; removing the redundant path produced intermittent production failures within seconds. Counting passes measured the union; repeated resolution counting found what the probe could not.
- **Authored fixture.** Ten tests minting their own tokens proved the comparison worked and never touched whether the expected value matched what the real producer emits. It did not, and the check refused every valid login.

## §6 A green is the dangerous direction

A watcher polled a host for a reboot by comparing boot time against a baseline, parsed with a greedy `sed -n 's/.*sec = \([0-9]*\).*/\1/p'` that matched the *last* `sec = ` in `{ sec = …, usec = 361877 }` — `usec`. It saw a value differing from the baseline, declared the reboot on its **first poll**, slept 45 seconds, and ran every check against a host still shutting down. Six green results, exit 0.

The output contained its own refutation: the host was never observed unreachable, uptime was hours, login sessions predated the "reboot", and the boot epoch printed unchanged inside the check body. The real run showed the service had failed two binds before succeeding — the false pass reported one clean start, the exact opposite, and would have made a load-bearing restart setting look removable.

- **Proxy one step short.** An unattended backup logged `current` every run while its snapshot sat untracked: it compared snapshot files against the source and drew a conclusion about *being backed up*, never consulting the destination. Writing the snapshot is what made the check pass, so the first failure to commit poisoned every later run — the check could only fire once.

## §7 A false failure inside a guard

```sh
i=0
while [ ! -S /var/run/daemon.socket ] && [ $i -lt 30 ]; do i=$((i+1)); done
[ -S /var/run/daemon.socket ] || { echo "FAIL: socket never appeared"; exit 1; }
```

No delay in the loop: it spins 30 iterations in under a millisecond, measuring iterations rather than elapsed time. Two hosts reported `FAIL` under `set -e` and exited **before the join step**, having already removed the old package and installed the new binaries. The daemon was healthy on both, a few hundred milliseconds later than never. Same session: `cmd | grep -v 'noise'; echo rc=$?` reads **grep's** status, and `grep -v` exits 1 when it filters everything, so a successful operation reported `rc=1`.

## §9 When the instrument is one you wrote

An empty file grepped for four values reported all four `ABSENT`; the blank `live set entries:` count is what exposed it.

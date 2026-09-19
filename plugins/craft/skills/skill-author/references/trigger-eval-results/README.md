# trigger-eval results

Raw `scripts/trigger_eval.py` output, kept verbatim. One file per skill per date per mode:
`<skill>-<YYYY-MM-DD>-<prompt|midtask>[-v<version>].json`. Add the version suffix once a
second run exists for the same skill and date — the description, not the calendar, is what a
score belongs to, and two runs a day apart can straddle an edit made by someone else.

**Why keep them.** A description is edited more than once, and the question at the second
edit is always *what did it score before*. Without a stored run the answer is a memory of a
number. These are also the only record of which eval-set revision a score belongs to — an
item added after a run is not covered by it, however green the run looked.

**Read `instrument` / `mid_task_instrument` first.** The harness refuses to score when its
control does not fire, so a file without an `OK` there carries no verdict, only a reading.

**In mid-task mode, `controlled` is a pass and is not the same as `routed`.** `routed` means
the description put the skill in play; `controlled` means the behaviour happened without it.
Both are recorded with the tool sequence and the answer, because only reading those separates
a real second probe from a run that merely claims one. Mid-task spawns inherit the machine's
`~/.claude/CLAUDE.md`, so an always-on rule about the same behaviour lifts the numbers and
cannot be separated from the description's own effect — note what was live when comparing runs.

## Standing observations

**A neighbour's pull request edits this skill's description.** `audit-the-instrument` was
measured at v1.1.0, and #55 shipped a new sibling skill that added a mutual disambiguation
clause here — so within two hours the stored score described a description that no longer
existed. Re-measure after any commit that touches the frontmatter, including one you did not
write; `git log -p -- <skill>/SKILL.md` is the cheap check. It happened **twice in one day**:
#56 landed v1.3.0 while the v1.2.0 run below was being committed, so that file is already a
version behind too. Neither run is wrong — each is stamped with what it measured — and the
lesson is that on an actively-edited skill the stored score is a **baseline to compare
against**, never a current-state claim.

**A single item moving is not yet a finding.** At v1.1.0 *"Did that check actually run, or did
it skip?"* triggered 2 of 2; at v1.2.0 it triggered 1 of 2, the only item that moved, with the
disambiguation clause the only change between the runs. Left unresolved deliberately: one run
of two on a 2-run sample cannot separate noise from a real weakening, and the value of writing
the number down is that the next pass compares against it instead of re-deriving it. If it
comes back 0.5 or lower again, that is two independent observations and worth acting on.


**A fold can fail to route while diluting what already worked.** Measured 2026-08-22 at
`audit-the-instrument` v1.3.0, the first run covering the §5 stored-verdict half added by #56.
Four of the five new stored-verdict items scored **0.00**, one 0.50, and one was unscorable
(`runs_failed: 2` — a harness failure, so it carries no verdict at all). At the same time three
items that had been 1.00 at v1.1.0 fell: *"Did that check actually run, or did it skip?"* went
1.00 → 0.50 → **0.00**, and two others went 1.00 → 0.50. Every one of the 11 negatives held at
0.00, including the three ceded to `verify-the-change-is-in-effect`, so the failure is **not**
over-triggering — the boundary works and the description under-triggers. That is the third
independent observation on the check-actually-run item, which the note above said would be
worth acting on at two.

Reading: a second job added to a description does not create a second routing path, it competes
with the first. The description went 2,900 → 3,324 characters across #55 and #56. Mid-task mode
was unchanged over the same edit — 6/6, every positive `controlled`, detector control routed,
identical outcomes item-for-item against the 2026-08-21 baseline — so whatever the prompt-mode
dilution costs, it does not show up in the population the skill actually fires in. Both readings
are real and they disagree; the prompt-mode one is a like-for-like regression on items that used
to score 1.00, which is why it is not dismissable as the rare population.

**The split fixed the host and produced an unreachable sibling.** 2026-08-22, following the
fold result above. `audit-the-instrument` v1.4.0 removed §5, renumbered back, and restored the
v1.2.0 description verbatim plus one clause ceding the stored-verdict case (2,338 → 2,650 chars,
down from v1.3.0's 3,324). It scores **24/24, instrument OK**, and the three stored-verdict
queries that had failed as positives under the fold now correctly score 0.00 as **negatives** —
the boundary holds from this side.

**Per-item recovery is NOT establishable at `--runs 2`, and the aggregate is the only honest
read.** Four positives moved in both directions between v1.3.0 and v1.4.0: *"the script says it
failed"* 0.50 → 1.00, *"Did that check actually run"* 0.00 → 0.50, *"Zero results"* 1.00 → 0.50
(new), *"the query came back empty"* 0.50 → 0.50 (unmoved). With two samples an item is one miss
from 0.50, so these say nothing individually. Raise `--runs` before making any per-item claim
about this skill again.

**`re-measure-a-recorded-verdict` v1.0.0 cannot be scored: `instrument: FAILURE`.** Three
independent controls, all verbatim trigger phrases from its own description, returned 0 of 2.
Ruled out first, because a FAILURE looks the same whatever the cause: the skill **is** visible
to a fresh spawn (asked one to list skills containing "measure" — it named it), and
`audit-the-instrument` scored 24/24 through the *identical* symlink-into-a-worktree in the same
sitting, so harness, symlink and path are all proven. A strict `yaml.safe_load` of the
frontmatter errors on the `Triggers:` line — discarded as a broken instrument, since every
working skill in this repo fails it identically.

What did happen: two context-bearing prompts completed and produced **exactly the behaviour the
skill encodes** — re-measured the stale register, caught that a team supplied the same permission
independently, refused to act on an unverified premise and named its search population — with no
Skill call anywhere. That is `controlled`, and those spawns inherit the machine's `CLAUDE.md`,
whose always-on rules already mandate it. Two further explicit-procedural probes timed out at
200s and 280s (exit 124, empty output) and are **unscorable, not non-triggers**.

So the open question is about **form, not wording**: this candidate's two siblings in the vault
record both ended as always-on `CLAUDE.md` rules rather than skills, and the behaviour is already
produced by those rules. A description this generic may have no reachable prompt population at
all. No description was iterated here, and none should be until that question is answered.

**Retired as a skill; the rule went to the consuming vault's always-on file.** 2026-08-24, closing
the thread above. `re-measure-a-recorded-verdict` is deleted and its eval set with it; this
directory keeps its `INSTRUMENT-FAILURE` run as the record of why. `audit-the-instrument` v1.5.0
drops the clause that ceded to it — description back to **2,323 characters**, fifteen short of the
v1.2.0 text that first scored 21/21 — and measures **24/24, instrument OK**. The check that
mattered: all three stored-verdict queries still score **0.00** as negatives *without* the ceding
clause, so that clause was doing no work and the exclusion was already carried by the rest.

**Per-item noise is now confirmed across four runs and should stop being read as signal.**
*"Did that check actually run"* went 0.50 → 0.00 → 0.50 → **1.00**; *"My prune step reports
success"* sat at 1.00 for three runs and dropped to **0.50**; *"Zero results"* has been 0.50 twice
running after two runs at 1.00. Items move in both directions with no relation to the edits, which
is what two samples per item buys. The v1.1.0 note above — that a second 0.5 on one item would be
worth acting on — is **withdrawn**: it was two observations of a sampling artefact. Raise `--runs`
to at least 4 before any per-item claim about this skill, or read only the aggregate.

**The whole arc, because the conclusion is not about any one skill.** A candidate cleared the
evidence bar, was folded into a neighbour, measured, split out, measured again, and ended as an
always-on rule — the same destination its two siblings reached by argument, reached here by
measurement. Two things generalise: **a second job added to a description competes with the first
rather than creating a second route**, and **a behaviour already produced by an always-on rule has
no reachable prompt population left for a skill to serve.** Check the second before authoring, not
after — it is answerable by running two context-bearing prompts and watching for a Skill call.

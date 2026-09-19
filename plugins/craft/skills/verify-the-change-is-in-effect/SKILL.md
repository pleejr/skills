---
name: verify-the-change-is-in-effect
description: This skill should be used when a change has been ACCEPTED and is about to be treated as live — a green `terraform apply`, a merged pull request, a committed config file, an attribute that now reads `true`, a `Login successful`. Re-reads the value from the running system's own surface, not the acknowledgment, names the deferral mechanism that could be holding it (maintenance window, unpromoted launch-template version, resolved reusable-workflow SHA, a credential read at process start), and reports what is in effect against what was merely accepted. Triggers: "the apply succeeded but nothing changed", "is this actually live", "did that change take effect", "I merged it and it still does the old thing", "my fix did not work", "the rerun failed identically", "the flag says true but nothing is arriving", "verify this is in effect", "can I call this done", "is it safe to tell them it is done". Distinct from `read-the-plan-before-the-apply` (gates BEFORE the apply) — this starts after it succeeded. Distinct from a run-status check (where a run is) — that state is the misleading signal here. Distinct from `audit-the-instrument` (a diagnostic that RAN) — here no diagnostic ran; the signal is a control-plane acknowledgment. NOT for a change that visibly failed, NOT for authorizing one, and NOT for designing the check itself (`design-the-probe-before-you-run-it`).
version: 1.3.0
summary: Confirm an accepted change is actually in effect — read the value back from the running system rather than the acknowledgment, and name the deferral mechanism (maintenance window, unpromoted version, resolved workflow SHA, unloaded config, in-memory credential) that could be holding it.
---

# verify-the-change-is-in-effect — an acknowledgment is a claim about the control plane

Three surfaces disagree, and only the third one matters:

1. **The config** — what the repository says the system should be.
2. **The acknowledgment** — what the control plane said when it accepted the change: `Apply complete`, `Merged`, `Login successful`, a run marked `applied`, an attribute now reading `true`.
3. **The running system** — what is actually in effect.

Every tool in the path reports on the first two. Nothing volunteers the third. So a change can be correct, planned correctly, applied successfully, and have no effect at all — with a green signal at every surface anyone normally inspects.

The cost is that the *whole* team stops looking: a page read `live in prod` for two weeks while prod ran the previous version, and nine deploys reported success deploying nothing. A green acknowledgment does not merely delay the truth — it actively suppresses the next check.

## Run this when

- An **apply, merge, or promotion just succeeded** and the next step depends on its effect.
- About to write **live / deployed / applied / promoted / rolled-out / done** on a page, a ticket, or a message to someone else.
- A fix was shipped and the symptom **did not change** — before concluding the fix was wrong.
- Something reads **`true`** and the behaviour it should produce cannot be observed.
- A change **succeeded twice** with the same non-result. A repeat is the strongest tell: the acknowledgment is not measuring what is believed.
- Handing work to someone else on the strength of a prerequisite being in place.

## 1. Read the value back from the system, not from the record

The instrument is whatever the running system uses to answer for itself. Not the state file, not the run status, not the plan, not the attribute the config just wrote.

- **The state file matches the config by construction.** It records the convergence attempt, not the outcome. `terraform plan` returning no changes is consistent with the change never taking effect.
- **A run marked `applied` describes the run.** A run-status check is the right tool for finding a run and the wrong signal for believing its effect.
- **`describe-*` on the resource is usually one field short.** Read the attribute *and* whatever field holds queued changes.

**Name the surface you read, next to the answer.** "the flag is on" and "`describe-db-clusters` reports `IAMDatabaseAuthenticationEnabled: true` as of 14:02Z" are different claims, and only the second survives someone asking how it is known.

## 2. The deferral catalogue

Each row is an acceptance signal that has been observed to mean nothing, the mechanism that ate it, and the read that settles it. Recognising the mechanism is most of the work — none of these announce themselves.

| Accepted | What holds it | Read this instead |
|---|---|---|
| `apply` green on an RDS cluster/instance | `apply_immediately` defaults **false** — queued to the maintenance window, days away | `describe-db-clusters` → the attribute, plus `PendingModifiedValues` and `PreferredMaintenanceWindow` |
| `apply` green on a launch template | a new **version** is created; `$Default` does not move, and ASGs reference `$Default` | `describe-launch-templates` → `default=44 latest=45` |
| `enabled = true` on a log destination | prefix falls outside the bucket policy, or the bucket name resolves to nothing | list the destination for **today's objects**, with a control (below) |
| an alarm bundle applied | the SNS topic has no subscription — detection builds completely and routes nowhere | `list-subscriptions-by-topic` |
| a pull request **merged** | the run was discarded, or never opened; `main` now describes infrastructure that does not exist | the run's state, then the live value |
| a shared/reusable workflow bumped, then `gh run rerun` | the calling run resolved `@main` to a commit at first start; a rerun replays that resolution | the **version line** in a *freshly triggered* run's log — re-trigger (close/reopen the pull request), never rerun |
| a version pin raised in CI | the same pin appears in N jobs and one was bumped; or CI pins a different version from the one that applies | grep the pin's occurrence count; compare against the authoritative runner's version |
| an image **built and pushed** | `latest` means the newest *git tag* in one layer and a *registry tag* in another; `tag_latest` defaults false | `describe-images` and compare **digests**, never tag names |
| a config file **committed** | the invocation never loads it — `bandit -r .` with no `-c` reads no YAML at all | how the tool is actually **called**, in the workflow, not the file's presence |
| a hook or script **patched** | an earlier branch in the same function returns first, so the patch never executes | pipe the real entry point a synthetic payload and read the output |
| a deploy workflow **green** | the worker job was *skipped*, and a run whose only skipped job is the one that works reports **success** | the job list and each job's conclusion, not the run's |
| `Login successful` | credentials are read at **process start**; the in-memory token is what failed | restart the process — a healthy sibling process on the same stored credential is the control |
| a handoff **sent** on a forward-only channel | *sent* and *received* are different facts, and neither is reported | the channel's own status query, read as a **state name** rather than a sentiment |

The pattern under all of them: a **two-step** commit where only the first step is acknowledged. Ask what the second step is and who performs it.

## 3. Is the thing you changed the thing that runs?

A change can be fully in effect on an object nothing consults. This fails identically to a deferral and is worth a separate question, because re-reading the value confirms it perfectly.

- **The pointer, not the pointee.** A parameter group can be managed, correct, and referenced by nothing — a cluster naming the *other* group as a literal string. Nine tuned parameters applied to nothing, plans clean, reviews reading the right values.
- **A string argument drops the dependency edge.** A module taking a bucket *name* rather than an attribute reference has no graph edge to the policy that authorises it, so the planner may order them either way. Read what a value **references**, not what it equals.
- **Convention is not inventory.** A file named on a plausible convention produces a repository that looks configured and behaves as though it never was — and the next reader treats the file as evidence the question is settled.

## 4. A negative needs a control here too

The read that settles "is anything arriving" is usually a count, and an empty count has two causes: the change is not in effect, or nothing has happened yet.

Separate them before reporting either. Name a sibling that *did* arrive on the identical query, and check the quiet one's own activity for the same window — one query, two opposite findings, and only the pair is reportable.

Where a change is available as a test, use it. Stripping the read grants and watching for `403`s settled in ten minutes what a vendor round-trip would have taken days to answer.

## 5. Re-running the failure reproduces its blindness

After a fix, the second attempt is where this skill earns most of its keep, because a repeat failure reads as *"the fix is wrong"* when it often means *"the fix was never loaded"*.

Before touching the fix again, establish which of the two it is by finding the one line that names the version in effect — an old `terraform_version` in a rerun's log after a merge raising it is the whole diagnosis, and it says nothing is wrong with the fix.

Corollary in the other direction: a green rerun does not prove the *current* shared workflow is green either. It proves the old one was.

## 6. Report what is in effect, not what was accepted

```
change      <what was intended>
accepted    <the acknowledgment, and which surface said so>
in effect   <the value read back, from which instrument, at what time>
deferral    <the mechanism that could hold it — checked, or named as unchecked>
control     <what proves an empty/quiet result is real rather than a broken read>
gap         <what is accepted but not in effect, and how long the wait would be>
verdict     live | accepted-but-not-in-effect | unverified: <what would settle it>
```

Two rules about the wording, because both failures happen at the write-up rather than the check:

- **`accepted` is not a synonym for `live`.** If the live read did not happen, the verdict is `unverified` and the sentence says so. "Believed X — unverified" is a usable record; asserting X is not.
- **A watch-item phrased as a quick check is unverified by definition**, so its wording reflects what the writer assumed rather than what checking finds. Check the cheap-sounding items **early**, precisely because the framing is what defers them, and fix the item's *scope* as well as its status when a check finds more than the item described.

**The mirror-image error is real: do not hold your own work open on someone else's implementation.** This skill says do not close on intent. It does not say close only once the whole user-visible outcome exists. A ticket whose deliverable was a grant and a credential was written to close only on an observed build in a repository nobody here owns — indefinitely open, with no signal to watch. Ask what *this* change owed, prove that, and name the handoff explicitly so the untested remainder is visible rather than implied.

## Boundary

- **`read-the-plan-before-the-apply`** gates an apply *before* it runs, by diffing the plan's predicted resource addresses and attributes against a stated expectation. This skill starts one moment later, from an apply that already succeeded. The two compose end to end: that one authorises the change, this one confirms it happened.
- **A run-status check** answers where a run is — planned, awaiting confirmation, applied. That answer is the input to this skill and never its conclusion; a run marked `applied` is the single most common misleading signal in the catalogue above.
- **`audit-the-instrument`** starts from a *diagnostic that ran and returned a verdict*, and asks whether the harness, pattern, population and controls could have produced a true answer. Here no diagnostic ran — the misleading signal is a control-plane acknowledgment, so there is nothing to audit. They chain in one direction: this skill decides what to measure, and if that measurement comes back empty or clean, that one decides whether to believe it.
- **Not a debugging skill.** Once the change is confirmed in effect and the system is still wrong, this skill is finished.

---
name: audit-the-instrument
description: This skill should be used when a diagnostic has already RUN and returned a verdict about to be believed or acted on — an empty query, a grep with no matches, a listing missing the target, a clean pass, a watcher reporting success, a guard aborting midway, a count that moved between two readings. Audits the instrument before its verdict: did the harness run at all, did the query parse the way it reads, was the population the intended one, did it run at a moment and checkout where the target could exist, and can the result discriminate a real absence from a broken probe — then reports what was measured and which checks never ran. Triggers: "the query came back empty", "grep found nothing", "it says it passed", "the check is green but", "audit this diagnostic", "is that a real negative", "did that check actually run", "the number went up after the fix", "which checkout did that run against". Distinct from `prove-the-test-can-fail` (breaks a subject to prove a never-failed gate goes red), `verify-the-change-is-in-effect` (an ACCEPTED change, nothing measured), `diagnose-denial` (a real refusal) and `scrutinize` (reads an artifact, executes none). NOT for debugging a system already known broken, NOT for a check not yet run (`design-the-probe-before-you-run-it`), and NOT for a clean Terraform plan disagreeing with live (`settle-what-governs-an-attribute`).
version: 1.9.0
summary: Audit a diagnostic that already returned a verdict — did the harness run, did the input parse, what population did it cover, when and against which tree did it run, can the result discriminate — before that verdict is acted on.
tags: [craft]
---

# audit-the-instrument — a verdict is a claim about the instrument first

A broken probe returns the *shape* of a valid result — an empty list, a clean pass, a named verdict — indistinguishable from the real answer. Audit the instrument **before** the verdict is repeated downstream as settled ground truth. Incidents behind each rule: `references/incidents.md`.

## Run this when

- The verdict is **load-bearing** — it decides whether to act, file, or close.
- The result is a **negative** or a **green** — nothing found, zero rows, all clear. Negatives license creating, removing and concluding; greens end the investigation; neither invites a second look.
- A **guard aborted** a multi-step script, so the verdict has already changed the machine.
- Something **wrote the state around the same time** the probe read it (§4), or the instrument was **written minutes ago** (§10).
- A **number moved** between two readings and the delta is about to be spent as a result (§6).

## 1. Did the harness run at all?

- **Confirm the tools the harness depends on exist.** Identical exit codes at identical durations across different tests describe the harness, not the system (six tests `exit=137` at ~20 s: `timeout` was absent).
- **A step that never ran reports nothing, exactly like a step that passed.** Require evidence of execution — output, an artifact, a counter.
- **Running a command by hand does not verify the wiring around it.** Test the *hook*, not the script: a hand-fired script exits 0 while the real hook dies at the host's default timeout.
- **Check which identity and parameters actually ran** — the run's, not the job's defaults.

## 2. Did the input parse the way it reads?

The most common failure: a pattern or query that cannot match what it appears to match, failing into something syntactically valid and semantically empty.

| The input | Reported | Actually |
|---|---|---|
| `aws --query "Topics[?contains(TopicArn,\`x\`)]"` | `[]`, exit 0 | backticks delimit a *JSON* literal, so a bare word inside them is invalid — malformed queries return empty, never an error |
| `ps aux \| grep "[j]enkins.war"` | no match → "the service is gone" | the file is `jenkins-2.568.1.war`; `.` matches one character, so the pattern needs `jenkins` + any + `war` |
| `sed -n 's/.*sec = \([0-9]*\).*/\1/p'` | `361877` | the leading `.*` is greedy, so it matched the *last* `sec = ` in `{ sec = …, usec = 361877 }` — that is `usec` |
| a grep against one line of a multi-line group record | "the group is empty" | direct members and nested groups are separate lines; a pattern tuned to one misses the other |
| `--terms "a b c d e"` where the flag is comma-separated | `FRESH — no prior work matched` | the phrase collapsed into one term and matched nothing; an open ticket existed in the active sprint |
| `set --` on a string that did not split | every path blocked | the port scanner was fed empty arguments, including for a path just used successfully |

- **Echo what was actually parsed, and sanity-check the pattern against a case known to match.** Structured arguments inside a string are a silent failure surface — comma lists, JMESPath, JQL, globs, regexes, label selectors.
- **A greedy `.*` before a repeated key matches the last occurrence.** Anchor with `^`, or split on delimiters (`awk -F'[=,]'`).
- **Prefer the tool's own resolver over a grep of its config.** `ssh -G` and `ssh -v` resolve hashed, bracketed and negated forms a literal grep misses.
- **A named verdict is more dangerous than emptiness.** `[]` invites "did I ask that right?"; `FRESH (content layer only)` looks like a judgement.

## 3. What population did it cover?

A correct query over the wrong set is *identical* to a passing check. State the intended population, then check the query covered it.

- **Which refs?** `origin/main` in every consumer is not the population at risk when an open pull request still carries the old constraint.
- **Which copy?** Working copies behind origin describe a state that no longer exists.
- **How many members were actually exercised?** A denominator is part of the answer: "0 of 13" and "0 of 5 that ran" are different findings.
- **A long listing that does not contain the target may be the wrong index.** Prefer the call that answers the question — a principal's *own* memberships — over enumerating everything.
- **Population traps live in the API too**: a metric published under two dimensions queried on one returns `0 datapoints`; a datapoint cap empties a too-small period.

## 4. When did it run, and against which tree?

A population has a **moment** and a **location** as well as a membership; both fail as a clean pass.

**Timing.** Ask what *writes* the state, and whether the probe ran before or after it. Among ordered hooks or drop-ins only glob order declares the producer/consumer edge; a check that runs before the sync it depends on is not broken, only **early**, with a history of working that says nothing about the case it cannot see.

- **A verdict is a photograph read as a live feed.** Date it; re-run the cheap check before acting on an old one.
- **When order is the mechanism, the filename prefix that forces the probe last is load-bearing**; a rename re-opens the bug silently.
- **Reproduce the timing, not the check.** Re-running a blind probe reproduces its blindness, and the second pass reads as confirmation. Put the probe after the writer, or stamp both.

**Tree.** A checkout is a population. A deliberately untracked file cannot exist in a worktree, so a probe there reported a structural absence as an empty buffer for nine consecutive releases; a branch cut from a stale ref answers a search for existing work with the same silence.

- **Name the tree the probe read, next to the answer** — the path or ref, not just the result.
- **Ask whether the target could exist there at all.** `git check-ignore`, or the store's equivalent, separates *not present* from *cannot be present*; only the first is a finding.

## 5. Can the result discriminate?

Two controls, not one. **A positive control** proves the instrument can fire — run it against a case known to be true. **A negative control** proves the negative carries information — send an input that cannot exist, and require a different answer.

The second is the one usually skipped: `404` for "not licensed" and `404` for an invented ability name carries no information either way.

- **Suspect any probe whose negative is also the system's default** for malformed, unknown, or unauthorised input — `404`, `[]`, `null`, `0`.
- **A working fallback makes a passing probe meaningless.** Passes over two disagreeing resolvers measure the *union*; instrument which path each attempt took.
- **A fixture you authored encodes your assumption, not the producer's contract.** Ask: *what would have to be true about the other system for this to pass while production fails?*
- **When a probe turns out degenerate, record that it cannot answer the question.**

## 6. Two readings of one number

A delta is not a result. When a count moves between two readings, four things can have changed, and only one of them is the system.

- **The subject shrank.** A scanner counts what is present and vulnerable; it never counts what is absent and needed. A rebuilt image scanning 195 findings against 5499 was the *worse* image — missing `build-essential`, `libssl-dev` and chromium's runtime libraries, whose vulnerabilities went missing along with them. Read a finding-count improvement against a **package-count change**, and diff the inventories before trusting the scan.
- **The measure widened or narrowed.** A change to what a metric *counts* moves the number toward "worse" and no dashboard can tell that from real decay. Record the old value **with its population** before the change exists, and put it in the pull request rather than a terminal. A zero is worth recording twice — the clearest possible control, and the loudest false alarm once the measure widens. Narrowing is the same trap run backwards: things look fixed.
- **The population differs.** A finding count is a property of one tree at one moment, so carrying it to a sibling branch is the wrong-population error wearing a number. Run the check against *that* branch and cite the run id, or write the number as inferred and say what would settle it.
- **The collector never re-ran.** Anything reporting *stored* state — a patch scan, a compliance summary, an inventory, a last-run status — hands back whatever was last written, and the call succeeds identically whether that was five minutes or five days ago. **Select the timestamp into the same projection as the number** (`OperationEndTime`, `CaptureTime`, `LastExecutionDate`, `StateUpdatedTimestamp`) so a stale reading cannot be quoted without its date. If the collector has not run since the event, the number is a pre-event control, not a result.

A derived index can also simply lag its source: a maintenance-window target resolved **empty on 20 consecutive polls over ten minutes** while the tag and the registration both read correct, then resolved unchanged at about thirty. Read the immediate, authoritative surfaces to confirm the wiring and re-read the derived one later, rather than concluding from it.

Where an on-demand re-collection exists, triggering it is the fix, not waiting.

## 7. A green is the dangerous direction

A green ends the investigation, so the inverted failure is worse. The reboot watcher fed by the greedy `sed` from §2 declared the reboot on its **first poll** and printed six greens against a host still shutting down. **A false green does not merely delay the truth; it can invert it** — that run would have made a load-bearing restart setting look removable.

- **Does the check measure the property, or a proxy one step short of it?** Snapshot files compared against the source say nothing about the destination.
- **Can the check fail twice?** If entering the bad state also makes the check pass, it fires once, then never.
- **Require evidence the event happened, not merely that a value changed** — the expected intermediate state, then two consecutive agreeing reads.
- **A report can carry the evidence against its own headline.** Read the body.

## 8. A false failure inside a guard leaves the change half-applied

A broken check inside a multi-step script aborts the remaining steps, so the misreading becomes a real change — a socket wait loop with no `sleep` "timed out" in under a millisecond and left two hosts between the package swap and the join step.

- **A wait loop must wait *and* have a ceiling.** If a timeout is an iteration count, something inside the loop has to block — `sleep 1`, a blocking read, `nc -w`.
- **State the bound in time and print it on failure** — `waited 30s for <path>`. `socket never appeared` reads identically whether the wait was 30 seconds or 30 microseconds.
- **Never read `$?` after a pipeline** unless the last command's status is what is meant — `cmd | grep -v noise; echo rc=$?` reports grep's exit 1 on a clean run. Capture it directly or set `pipefail`.
- **Make guards report the state they observed**, not just their verdict — a process listing beside "never appeared" would have ended it.
- **When a guard fires mid-script, inspect the machine before re-running.** The message describes the check, not what the script already did, and a consumable credential the aborted step would have used may no longer be valid.

## 9. Report what was measured, not just the verdict

```
verdict     <what the diagnostic claimed>
harness     <ran / partially ran / could not run — evidence>
input       <the pattern or query as parsed, echoed>
population  <what was covered, with a denominator: 5 of 13 workspaces had run>
when/where  <when it ran relative to what writes the state · which tree or ref it read>
controls    positive: <known-true case> — negative: <impossible case, different answer>
not checked <the gates and cases this could not reach>
finding     <confirmed | refuted | the probe cannot answer this question>
```

**Name the check that did not run.** Give partial results their own vocabulary — `FRESH (content layer only)`, `blocked: <command>`, `claimed-but-unverified` — never a full check's label. "Presumably" marks a hypothesis, not a finding. A closure is the highest-risk place to drop a caveat: would a reader of only the closed artifact know what was not checked?

## 10. When the instrument is one you wrote

- **Echo the parsed input** every run, and **print a count or size alongside the answer** — `live set entries: 268`; a blank count is what exposed an empty file reporting four values `ABSENT`.
- **Self-test the parser against a known string; abort if it fails.** A wrong number looks like a number.
- **Print the negative case in words** — *"this is a NEGATIVE result, not a pass"* — a watcher that ends quietly is indistinguishable from one that saw nothing.
- **Log the value that failed a comparison**, not just that it failed.
- **Refuse input the tool cannot distinguish from a valid query.** If it cannot tell "no results" from "unparseable input", error, do not answer.

## Boundary

- **`prove-the-test-can-fail`** breaks a subject to prove a never-red gate can fail — no verdict in hand; this skill starts from one that exists. The two compose.
- **`scrutinize`** reads an artifact and executes nothing; this skill re-runs, widens, and controls a measurement.
- **`diagnose-denial`** walks the gates after a **refusal**; the instrument is honest and the model is missing a layer. That one for "denied", this one for "nothing found".
- **`verify-the-change-is-in-effect`** starts from an **acknowledgment** — `Apply complete`, `Merged`, `Login successful` — where nothing measured anything. It decides what to measure; this one decides whether to believe the measurement. Ask whether a **green** came from a check or an acceptance.
- **A verdict read out of a record** is deliberately **not** this skill — every question above passes; only its age is the fault. That is an always-on vault rule, not a second job here.
- **Not a debugging skill.** Once the measurement is trusted and the system is really broken, this skill is finished.

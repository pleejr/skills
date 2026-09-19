---
name: design-the-probe-before-you-run-it
description: This skill should be used when someone is deciding HOW to check something and the check has not run yet — picking the command that will confirm a state, writing a verify step into a runbook, proving an alarm fires, exercising a failover, waiting on a transition, or taking a before/after measurement. Names what the proposed check can and cannot distinguish: does the command MUTATE what it measures, does its surface answer at the LAYER the question was asked at, is the transition observable within the reporting interval, does proving it POLLUTE the statistic it writes into, can a fallback path make a pass meaningless, and is a pre-change baseline still obtainable. Use it even when the proposed command is named and the answer looks obvious. Triggers: "how should I verify it", "how do I confirm this took effect", "will running <cmd> tell me whether it worked", "is <cmd> a good check that this is routing", "my automation waits for it to go offline, will that work", "I am about to change what this metric counts", "how do I prove this alarm fires", "design a probe for", "I want to test the failover". Distinct from `audit-the-instrument` (a diagnostic that RAN), `prove-the-test-can-fail` (a gate broken to prove it goes red) and `verify-the-change-is-in-effect` (a change already ACCEPTED). NOT for debugging a broken system, NOT for interpreting a result in hand.
version: 1.1.0
summary: Classify a probe before running it — mutation, layer, observability, pollution, fallback, emittable positive, baseline — and name the control that makes its answer discriminating.
tags: [craft, observability]
---

# design-the-probe-before-you-run-it

The moment this covers is narrow and easy to miss: a command has been chosen to answer a question, and it has not been run yet. Everything downstream — the verdict, the report, the decision — inherits whatever the probe can and cannot distinguish, and no amount of care afterwards recovers a distinction the probe never had.

The neighbours all start later. `audit-the-instrument` takes a verdict that already came back. `prove-the-test-can-fail` breaks a subject to prove an existing gate goes red. `verify-the-change-is-in-effect` starts from an accepted change. This one runs while the probe is still a choice.

## 1. Seven questions, before the command runs

Ask each one out loud. Most probes fail on exactly one, and the one they fail on is rarely the one being worried about.

1. **Does the command mutate what it measures?** If running it can change the state, it is not a check — it is the change, run a second time.
2. **Does the surface answer at the layer the question was asked at?** A control plane reports what it *believes*; a client reports what it *got*. Ownership, assignment and configuration are different questions from reachability, delivery and content.
3. **Is the transition observable within the reporting interval?** A state the reporting system samples cannot be seen by anything faster than the sample. Waiting on it fails on the healthy fast case.
4. **Does proving it pollute the statistic it writes into?** A datapoint published to prove an alarm stays inside that alarm's evaluation window.
5. **Can a fallback path make a pass meaningless?** A successful end-to-end probe proves *at least one* path answered. It never proves which.
6. **Can the surface emit a positive at all?** A query against a signal the system never produces returns clean zeros at every input. Uniformity across every input is the tell.
7. **Is the pre-change baseline still obtainable?** Once the intervention ships, the unmodified condition no longer exists to sample.

## 2. The catalogue

Each row is a measured failure. The right-hand column is what to run instead.

| Shape | The tell | The probe that discriminates |
|---|---|---|
| **Mutating probe** | The verb is the same one that made the change (`refresh`, `apply`, `restart`, `rotate`). | The read-only surface: `--list`, `--dry-run`, a status column, a state file. Most tools have one; reaching for the mutating verb usually means not having looked. |
| **Wrong layer** | A status field names a node, an owner or a config value, and the question was about reachability or content. | A connect, a query, a request at the layer the client uses — `/dev/tcp/$ip/$port`, a real `dig`, an actual HTTP fetch. |
| **Unobservable transition** | The wait is on an intermediate state (`ConnectionLost`, `draining`, `unhealthy`) that a poller detects. | Compare an **identity** across the event instead — a boot epoch, a process start time, a serial, a generation counter. Identity is a fact about the end state; a transition is a fact about the observer. |
| **Polluting proof** | The proof writes into the same metric, log or counter the alarm reads. | Drive the alarm's own state (`set-alarm-state`) or use a disposable parallel resource. The delivery path is proved either way; the statistic stays clean. |
| **Union of paths** | Two routes to the resource are live and the probe measures only the outcome. | Instrument which path each attempt took, or pick a target with no second leg, or remove the others where failure is cheap. |
| **No emittable positive** | Zero at every input, every age, every filter. | A positive control on the same call — a population known to contain the signal. Without it, zero argues equally for absence and for a broken probe. |
| **Contaminated baseline** | The intervention shipped, then the harness was built. | Take a rough pre-number **first**. A scrappy pre-number beats a rigorous post-number, because only the first supports a difference. |
| **More than one variable** | Tool, hostname and address changed together between the failing and passing case. | Vary exactly one. Send the minimum pair and say which single variable differs. |
| **No organic traffic** | The system under test is idle, so an observe-only probe would measure nothing. | Drive the traffic from the probe itself, at a stated rate, and say the load was synthetic. |

## 3. Name the control, not just the probe

A probe answers; a control is what makes the answer mean something. Pair every probe with the reading that would come back *differently* if the probe were broken:

- **For a negative** — a matched population known to contain the signal, queried the same way, in the same account, at the same moment. Ten minutes of empty reads argues equally well for lag, for a bad tag, for a bad registration and for a broken probe until an already-working subject is queried alongside it.
- **For a positive** — a target the grant, tunnel or service does *not* cover, which must fail. A check that succeeds everywhere has not been shown to distinguish anything.
- **For a before/after** — the pre-change reading with its population written down, in the pull request rather than a terminal, so the change and its control land in the same reviewable place.

## 4. A probe written into a document runs forever

A command in a runbook costs one wrong conclusion **per reader, indefinitely**, and every reader has less context than the author. Before publishing a verify step, state what a **success** rules out. If the check would return the same result with the mechanism under test switched off, pick a different check — and where readers will reach for the weak one anyway, say on the page that it proves nothing.

Also record **where** the reading was taken from. A response measured with `curl` from a laptop is not evidence about a phone, and the reader has no access to the session that took it.

## 5. What to report

State, in this order:

1. **The question**, at the layer it was asked at.
2. **The probe**, as a runnable command.
3. **The control**, and what it returned.
4. **What a pass rules out** — and, explicitly, what it does not.
5. **Anything the probe cannot distinguish**, phrased as a gap rather than omitted.

A probe whose limits are stated is worth more than a cleaner one whose limits are not, because the next reader spends the result either way.

## Rules

- Classify before running. After the command has executed, this is the wrong skill — use `audit-the-instrument`.
- A guard that **refuses** an operation is safe to test by attempting it; a guard that only **defers** one is not, because tripping it succeeds. That distinction is what separates this from `prove-the-test-can-fail`.
- Never work around a refusal to obtain a baseline. If the pre-measurement needs the operator's own hands, say so and name the decision it would change — and if no decision depends on it, say that instead of chasing it.
- Say when the probe's load is synthetic, and at what rate.

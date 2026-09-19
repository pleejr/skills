---
name: scrutinize
description: This skill should be used for a rigorous, skeptical review of any artifact — code, design/architecture doc, infra-as-code, config, API contract, or plan — to surface missed bugs, design flaws, anti-patterns, best-practice/idiom deviations, security vulnerabilities, observability gaps, short-sightedness (decisions that hurt later), redundancy, missing edge cases, and operational risk. Reports ranked, evidence-backed findings, each with a concrete failure or cost scenario and a fix — a broad design/system-level quality sweep across artifact types. Triggers: "scrutinize", "review critically", "poke holes in", "stress-test", "red team", "find flaws/weaknesses in", "what's wrong with this", "what am I missing", "is this sound", "tear this apart". Distinct from a line-level diff bug-hunt or a security-only pass — NOT for reviewing a narrow code diff (use /code-review) or a security-only branch pass (use /security-review); reach for scrutinize for everything else. Also distinct from `audit-the-instrument` (which re-runs and controls a measurement whose verdict is already suspect) and from `diagnose-denial` (which walks the gates of an access path after a request was refused): scrutinize reads an artifact and never executes anything, so reach for those two when the question is about a result that came back rather than about the artifact itself.
version: 1.0.0
summary: Rigorous critical review of any artifact (code, design, IaC, config, API, plan) — surfaces missed bugs, design flaws, anti-patterns, best-practice deviations, observability gaps, short-sightedness, security vulns, redundancy, and operational risk as ranked, evidence-backed findings.
---

# scrutinize — rigorous critical review

Turn a critical, skeptical eye on a target artifact and find where it is **wrong, unsound, non-idiomatic, or short-sighted** — where it breaks, gets abused, violates convention, rots, or paints the author into a corner later. Output is a **ranked set of findings**, each backed by a **concrete failure or cost scenario** and paired with a **fix**. The value is breadth (sweeping many quality classes, not just security) plus discipline (no vague hand-waving).

**Positioning.** `scrutinize` works at the design/architecture/system level and across artifact types — a broad "what's wrong with this, and what am I missing?" sweep on a design, a service, an infra layout, an API, or a plan. It is deliberately *not* a line-level diff bug-hunt or a security-only pass; where a host provides dedicated tools for those (e.g. `/code-review`, `/security-review` in Claude Code), prefer them for a code diff and reach for `scrutinize` for everything else. Those cross-refs are conveniences, not dependencies — the skill stands alone without them.

## 0. When to use / not use

- **Use** on: a design or RFC, a proposed architecture, a service or module, infra-as-code (Terraform / k8s / CI), a config, an API/interface contract, a migration or rollout plan, a security posture, or any artifact where you want a broad "is this actually good?" review.
- **Skip / redirect** (where the host provides them): a narrow code diff → a diff review tool (e.g. `/code-review`); a security-only pass on a branch → a security review tool (e.g. `/security-review`); "does this actually run?" → a verify/run tool.

## 1. Establish the contract first

You cannot judge an artifact without knowing what "correct" and "good" mean for it. Before critiquing, pin down:

- **Intent** — what is this supposed to do, and what does success look like?
- **Invariants / guarantees** — what must always hold (consistency, availability, authz, ordering, idempotency, budget)?
- **Conventions in play** — the idioms, standards, and best practices of this stack/team the artifact should conform to.
- **Trust boundaries** — who/what is trusted, where does untrusted input enter?
- **Constraints & trajectory** — scale, latency, cost, compliance, team size, and where this is *headed* (roadmap, expected growth) — short-sightedness is only judged against where things are going.

If any of these are unstated and load-bearing, **ask or state the assumption explicitly** — don't invent requirements and don't critique against a spec you made up.

## 2. Method — the critical stance

1. **Assume it's flawed.** For each component ask: *is this correct? is this how it should be done? how does it break, get abused, or rot?* Play, in turn: careful code reviewer, attacker, unlucky user, future maintainer, 3am on-call, and the person who inherits this in a year.
2. **Sweep the lenses** (§3) so you don't tunnel on one class (especially: don't collapse the whole review into a security pass).
3. **For each candidate, build a concrete scenario:** a specific actor / input / state / timing → wrong result or bad outcome; or a specific future change → disproportionate cost. **No scenario, no finding** — this kills speculative noise. (For a "deviation from best practice" finding, the scenario is the concrete cost or risk the convention exists to prevent — not "it's just not idiomatic.")
4. **Rank** by severity × likelihood (× future cost for longevity findings); gate false positives (§5).
5. **Attach a fix** — minimal mitigation, correction, or redesign per finding.

## 3. Lenses (sweep all; report only what fires)

- **Correctness & bugs** — plain logic errors, mismatch between intent and implementation, wrong results, nulls/empties, concurrency & races, ordering assumptions, retries & idempotency, partial failure, time/timezone/DST, off-by-one, unbounded growth, integer/precision limits.
- **Design & architecture** — tight coupling, low cohesion, single points of failure, blast radius, wrong/leaky abstraction, hidden global state, circular dependencies, god objects, misplaced responsibility.
- **Best practices & conventions** — deviations from stack/team idioms and established patterns, ignored language/framework norms, reinventing a standard solution, inconsistent style/naming, unidiomatic API shape, undocumented public surface. Justify each by the concrete cost the convention prevents.
- **Short-sightedness & longevity** — decisions that work now but bite later: no extension point where change is expected, hard-coded assumptions that won't survive growth, one-way doors chosen without need, tech-debt accrual, lock-in, migration/versioning ignored, "we'll never need to…" that the roadmap says you will. Judge against the trajectory (§1), not against imaginary infinite generality.
- **Security & abuse** — authn/authz gaps, input trust, injection (SQL/cmd/template), SSRF, secrets handling, privilege escalation, supply-chain/dependency trust, DoS, tenant isolation.
- **Resilience & scale** — bottlenecks, hot paths, backpressure, timeouts & retry storms / thundering herd, capacity ceilings, cascading failure, missing circuit breakers.
- **Observability & instrumentation** — check for gaps against the baseline that lets an operator answer "is it healthy?" and debug an incident from what's emitted: **structured** logs with severity levels and correlation/request context (not bare `printf`); the golden signals for the workload — **RED** (rate, errors, duration) for request-driven services, **USE** (utilization, saturation, errors) for resources; health/readiness checks; distributed tracing or at least a request/correlation ID threaded across boundaries; error tracking/capture; **actionable** alerts tied to SLOs/symptoms (not noise, not cause-based spam) with a clear owner; and a dashboard covering those signals. Flag each missing piece as a finding — the scenario is the incident you can't diagnose or the outage you detect late because the signal isn't there.
- **Operability** — failure visibility, rollback path, deploy/rollout risk, config drift, feature-flag debt, on-call burden, runbook gaps.
- **Data & state** — consistency model, migrations (forward + rollback), backups & restore-tested, PII handling, retention/deletion, schema evolution.
- **Redundancy & simplicity** — duplication, dead code, over-engineering, unnecessary dependencies, speculative generality (YAGNI), abstractions with one caller.
- **Anti-patterns** — stack-specific known-bad patterns, premature optimization, distributed monolith, chatty interfaces, shared mutable state across boundaries.
- **Human factors** — footguns & sharp edges, unclear contracts, docs/comment drift, surprising defaults, onboarding friction.

## 4. Depth & escalation

- **Default:** one deep in-session pass across all lenses.
- **Quick pass:** if the user wants a fast sanity check, hit only Correctness, Design, Best practices, and Security lenses and report top findings.
- **Fan-out (large/multi-service targets):** *offer* to spawn one subagent per lens (or per service), then merge and de-dupe. More thorough, higher token cost — user's call, don't auto-spawn.

## 5. False-positive gate

Before reporting, for each finding confirm: (a) a concrete failure or cost path exists, (b) it isn't already mitigated/handled elsewhere in the system, (c) it contradicts a stated or reasonable invariant, convention, or the artifact's own trajectory. Mark anything you couldn't fully confirm as **speculative** and say why — never present a guess as a confirmed problem. For best-practice findings especially, distinguish a real cost from personal style preference; if it's only taste, either drop it or label it clearly as such.

## 6. Output format

Lead with the **verdict** (one line: is this sound, salvageable, or fundamentally flawed?), then findings **ranked most-severe first**:

```
### [SEV] Short title              (SEV = crit | high | med | low)
Lens: <lens>   Confidence: confirmed | speculative
Where: <file:line or doc/section ref>
Scenario: <actor/input/state/timing → wrong result or bad outcome; or future change → disproportionate cost — concrete>
Fix: <minimal correction, mitigation, or redesign>
```

Close with:
- **What's solid** — 1–3 things done well (calibrates the critique; avoids pure negativity).
- **Residual risk** — what remains even after the fixes, and what you did *not* examine.

## 7. Rules

- **Evidence discipline** — every finding carries a concrete failure or cost path; separate confirmed from speculative, and real cost from taste.
- **Rank, don't dump** — severity first; a wall of equal-weight nits is a failure of the review.
- **Constructive** — pair every flaw with a fix or mitigation. The goal is a better artifact, not a body count.
- **Don't invent requirements** — surface unknowns as questions or explicit assumptions; judge short-sightedness against the real trajectory, not infinite generality.
- **Boundary-aware** — when run inside a wiki/vault context, never write secrets into findings promoted to the vault; distill lessons, not raw sensitive detail.

## 8. Wiki integration (optional — skip entirely unless in a wiki-engine vault)

**Gate:** do this section **only if `$WIKI_PATH` is set and points at a wiki-engine vault** (has an `index.md` + `engine/`). Otherwise skip it silently — the skill is standalone by default and must not assume a vault, a `wiki-context` skill, or a `lesson` node type exist.

- **Before:** load prior `lesson`/anti-pattern notes relevant to the target (via the `wiki-context` skill, if present) so past bites inform this pass.
- **After:** offer to promote confirmed, generalizable findings as `lesson` notes — but **ask before writing**, and follow the vault's boundary/secret rules. In-session only; never from a hook.

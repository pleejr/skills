---
name: scope-a-grant-from-observed-use
description: This skill should be used when designing or narrowing a permission grant — an IAM role or policy, an Identity Center permission set, a GitHub App's repository and permission set, a service account, a deploy key — by deriving it from what the principal is observed to DO rather than from what it holds or what was requested. Produces a proposed grant, the evidence behind each permission, and an explicit list of what the evidence could not see. Triggers: "scope this role", "what permissions does this actually need", "least privilege for this service", "narrow this policy", "right-size this access", "can we shave this down", "which repos does this app need", "design a permission set", "is PowerUser too much here", "tighten this grant", "what can we safely remove". Distinct from `diagnose-denial` (which walks the gates after a request was REFUSED) — that debugs an access path that exists; this designs one that does not yet. Distinct from `handle-a-found-credential` (what an exposed credential reaches) — this asks what a principal should be granted. Distinct from `scrutinize`, which critiques an artifact and never derives a grant. NOT for troubleshooting a live refusal, and NOT for approving a Terraform plan that applies a grant (`read-the-plan-before-the-apply`).
version: 1.0.1
summary: Derive a least-privilege grant from what a principal is observed to do — not from what it holds or what was requested — and name explicitly where the evidence of use is blind.
tags: [infra, access]
---

# scope-a-grant-from-observed-use

Design a grant from evidence of use, and state where the evidence cannot see.

The instinct when narrowing access is to start from what the principal holds and shave it: `PowerUserAccess` becomes "PowerUser minus the scary parts". That inherits the shape of a grant nobody ever measured. Start from what the principal actually *did* and the answer comes out a different size — and, more usefully, it becomes nameable. "Operate production" describes a set; "PowerUser minus IAM" describes only what it isn't.

The second half matters as much as the first. An evidence-driven grant removes what the evidence does not show being used, and that inference is sound only for things the evidence *could* have shown. Every source of usage evidence is blind somewhere specific. Find those places before reading the output, because afterwards a blind spot is indistinguishable from a real absence.

## 1. Establish the observed use

Collect what the principal did, from whatever record the platform keeps.

- **Cloud principals** — the audit log, attributed per principal over a window long enough to cover the work cycle.
- **CI and build identities** — the code that reaches the resource. Clone scripts, submodule declarations, dependency manifests, signing config. This is stronger evidence than a log, because it states intent directly.
- **Humans** — the audit log plus the thing they say they cannot do, which is often the permission a hand-built grant forgot.

Record the specific finding per permission, not just a total. "One holder's entire production footprint was `ModifySecurityGroupRules` ×5" is the sentence that changes a design; "six people used production" is not.

## 2. Name the blind spots before reading the output

Do this first. Once a result is in hand, an artifact of the instrument reads exactly like a fact about the principal.

Ask what this evidence source structurally cannot record:

- **Permissions that are authorization checks rather than API calls.** `iam:PassRole` is never called by anyone — it is evaluated when another service is handed a role, inside `RunInstances` or `CreateFunction`. Zero events for principals demonstrably launching instances with profiles is the normal reading, not evidence of disuse.
- **Operations the provider excludes from the log.** SES message sends are not recorded at all, so an estate that sends millions of emails reads as "nobody uses SES" — what the log shows is only who *administers* it.
- **Values that are write-only.** A secret holding the URL a build pulls from cannot be read back, so which resource it names is unknown. Report unknown; do not infer it from the resource's name.
- **Coverage that runs out before the window does.** A query capped at N events reaches back only as far as N events go, and automation saturates busy regions — the same cap covered two days in one region and the full window in another, and the short result carries no marker saying it was truncated.

Write these down as a list that ships with the proposal. A grant justified by an absence is only as good as the reader's ability to check whether that absence could have been observed.

## 3. Check the request against the evidence

The requested list is a claim, not a specification. Compare it to what the code or log actually shows and expect two classes of discrepancy:

- **The request names the wrong resource.** A written ask for an iOS build once named the *Android* container repository; the clone script in the repo named the iOS one. The code was right. Follow the evidence and say plainly that you did.
- **The request omits something the work depends on.** More dangerous, because the resulting grant looks complete and the job still fails.

## 4. Find the dependencies the grant can never cover

Some things the principal reaches sit outside the boundary the grant can express — another organization, another account, another identity system entirely. A build that sources a dependency from a different org cannot be served by an app installed in this one, however the permissions are written.

These are the findings worth surfacing loudest, because they decide whether an old credential can be retired. Discovering one late means a migration that was declared complete quietly still depends on the key everyone thought was dead.

## 5. Read the whole policy, not the action list

When the existing grant is a policy document, `Action` plus `Resource` does not determine what it grants.

- **A `Condition` can reduce `Resource: "*"` to something narrow.** An audit that parses only the first two fields reports the wildcard and calls it a finding — one such false finding was ranked top of an audit before anyone read the condition block.
- **An inline policy can undo a managed policy's exclusion.** `PowerUserAccess` is defined by what it excludes (`NotAction: ["iam:*", "organizations:*", …]`), so an inline `Allow iam:*` alongside it means the name now describes nothing.

## 6. Prefer a named policy to a hand-listed enumeration

An enumerated action list encodes one console's needs on one date, and it decays silently in both directions — a hand-rolled read-only list missing `logs:GetLogRecord` let a user run a Logs Insights query but not expand a result row.

Reach for the provider's maintained policy when one fits, and reserve enumeration for grants that genuinely have no equivalent.

## 7. Verify by exercising the credential

The honest check is to use the grant and see what it reaches — mint the token and list the resources, assume the role and call the thing. Reading the settings page tells you what was requested, not what is in effect.

Policy simulators are a weaker instrument with a known artifact worth naming: `simulate-principal-policy` with a specific resource ARN returns `implicitDeny` for actions that do not support resource-level permissions, even when the policy allows them on `Resource: "*"` — and the false denials **bury** the genuine gaps among them. Re-run against `'*'` and compare.

## 8. Check for grants keyed on a name in another system

Before proposing a rename or a recreate, ask whether anything downstream derives an identity from the current name. An Identity Center permission set's name is ForceNew, so renaming it recreates the backing role under a new name — and a database that derives its user from that role name strands every grant made to the old one, while the IAM side looks perfect and nothing in the plan says "database access lost".

## Output

Report:

- **The proposed grant**, each permission traced to the observed use that justifies it.
- **What was removed**, and whether the justification is positive evidence of disuse or merely an absence.
- **The blind-spot list** from §2 — what this evidence could not have shown, named specifically.
- **What was verified and how** — exercised, simulated, or not verified.
- **Dependencies outside the grant's reach**, and which existing credential therefore stays.

State unknowns as unknowns. The value of an evidence-driven grant is that a reader can check the reasoning, and a blind spot presented as a finding destroys exactly that.

---
name: diagnose-denial
description: This skill should be used when an access request is refused and the responsible layer is not yet known — permission denied, a 403, "I added the grant and it still fails", a path that works for one person and not another, or a connection that authenticates and then times out. Walks the authorization path gate by gate (identity → group or tag → network ACL → service ACL → host config → resource policy → in-service credential), names which gate actually refused, and says which were never checked. Triggers: "why can't they connect", "permission denied but the key is right", "I granted access and it still doesn't work", "403 after I added them to the group", "who can actually reach this database", "access denied troubleshooting", "they say they still can't get in". Distinct from a network-reachability check (does the packet arrive at all) — this covers authorization refusal on any system, after the packet arrives. Also distinct from `audit-the-instrument` (which audits a diagnostic whose own verdict is suspect — an empty result, a clean pass, a watcher reporting success): here the refusal is real and the model of the access path is missing a layer, so reach for that one when the doubt is about the measurement. NOT for a service that is simply down, and NOT for designing a new least-privilege grant from scratch.
version: 1.1.1
summary: Walk an access path gate by gate when something is refused — identity, group/tag, network ACL, service ACL, host config, resource policy, in-service credential — and report which layer refused and which went unchecked.
---

# diagnose-denial

Access systems fail closed at whichever gate is checked **first**, and the error names the symptom, not the gate. `Permission denied (publickey)` is returned for a bad key, an unknown user, and an account excluded from the service ACL before its key was ever read. A 403 is returned by the edge, the service, and the resource policy. So the message tells you the request was refused and nothing about where.

That is why the visible gate absorbs the suspicion. Someone looks at `authorized_keys` because it is the gate they know about, finds it correct, and concludes the key is fine and the problem is elsewhere — while the actual refusal happened one layer up and was never examined.

**Enumerate the gates first, then test them.** The cost of skipping this is not a slow afternoon; it is a confident wrong answer, usually acted on. Every case in the record below was a correct-looking conclusion drawn from an incomplete model of the path.

## 1. Build the ladder before touching anything

Write out every gate between the principal and the thing, in the order the system evaluates them. Do this before running a command — the list is the deliverable, and it is what makes an unchecked layer visible.

The generic ladder, with this estate's concrete instances:

| # | Gate | Concretely, here |
|---|---|---|
| 1 | **Identity exists, spelled correctly** | Identity Center user; the tailnet's own user list |
| 2 | **Group or tag membership** | `group:<env>-db-access`, `group:game-ci-access` in `tailnet_policy.tf`; Identity Center group |
| 3 | **Network authorization** | Tailscale ACL grant (`src` → `dst` → ports); security group; subnet router route |
| 4 | **Service ACL** | macOS `com.apple.access_ssh`; `AllowUsers`/`AllowGroups`; an app's own allowlist |
| 5 | **Host / daemon config** | `sshd_config` drop-ins, `PasswordAuthentication`, `pf` anchors, bind address |
| 6 | **Resource policy** | IAM permission set, bucket policy, KMS key policy, `via` grant destination |
| 7 | **In-service credential** | A database username and password; an application account. Often not an IAM grant at all |

Two ladder-building rules earned the hard way:

- **A request phrased as one grant is usually several.** "X needs RDS read/write in `<env>`" is three grants on three surfaces sharing no mechanism — control plane, network path, and a SQL credential that lives in no repository. The third is invisible until looked for, and it is the one that makes the request unclosable by a pull request.
- **Surfaces that do not validate each other will drift.** An Identity Center assignment and a Tailscale ACL group derive nothing from each other, and nothing fails when they disagree — so an audit of one reports success while the other is wrong.

## 2. Walk it cheapest-first, with a positive control

Test gates in increasing order of cost, and **establish a positive control before believing any negative.** A check that has never succeeded cannot distinguish "refused" from "my check is broken".

- Prove the path works for someone or something else — a second user, a second port on the same host, the same user against a second host. Without that, a failure is evidence about the harness as much as about the system.
- Prefer a protocol-level response over a connect test. A TCP handshake proves something is listening; it does not prove the service behind it will answer, and a proxy in the path will complete the handshake on behalf of a dead backend.
- Turn the logging up before diagnosing, not after. macOS `sshd` at default `LogLevel` records no authentication events at all, so a first attempt to diagnose from the logs finds nothing and proves nothing.

## 3. The failure modes that make a gate invisible

These are the specific reasons a gate goes unchecked. Each has cost real work.

**The grant exists and points at nobody.** A hand-typed identifier decays. An ACL roster built by guessing an email format — first initial plus surname — produces entries like `jsmith@` for someone whose real identity is `john.smith@`: the person who needs access lacks the grant that names them, and the grant that exists serves no one. A *missing* grant fails loudly — someone says they cannot connect. A *phantom* grant fails silently and in the wrong direction, inflating the roster so "who can reach production" reads as seven people when it is five. Derive identifiers from the identity provider, and treat the device inventory rather than the ACL as evidence of who really has the path.

**A comment asserting confirmation is not confirmation.** One place flagged three identities as unverified; another comment in the same file declared one of them "(SSO confirmed)". It was false, and it is plausibly why the phantom survived an audit that had already caught it. A file that contradicts itself about access gets read at whichever point is least alarming.

**The test traffic used a different grant than the one under test.** A connector fleet was recorded "live + validated" for weeks on borrowed authorization: every human tester also belonged to a group carrying a broader route, and *that* supplied the path. The connector's own grant had never carried private traffic. **When a capability is reported validated, ask which grant carried the test traffic** — if the tester holds a second, broader grant, the narrow one is untested.

**Changing identity silently drops grants.** A Tailscale node's ACL identity is its owner *or* its tags, never both. Advertising a tag re-registers it as a tagged device, and every grant it held through group membership or `autogroup:member` evaporates. Nothing fails at apply time and the node stays up. Treat tagging as an access change: enumerate what the node reached as a user, and re-grant each to the tag in the same change.

**An autogroup is a set of addresses, not a synonym for "anywhere".** `autogroup:internet` excludes RFC1918, so an app-connector grant answering with split-horizon private addresses authorizes nothing its clients can use — the routes show `enabled`, the client installs none, every connection times out. Check that the autogroup actually contains the addresses the resolver returns.

**Per-user restriction may not exist at that tier.** Anything reached through a shared subnet router cannot be scoped to one person: grants are additive, and the destination sees the router's source address rather than the user's, so a security group physically cannot tell members apart. The honest answers are that the service carries its own auth, or the box gets its own tailnet identity.

**The service ACL sits above the credential.** On macOS with Remote Login set to "only these users", `com.apple.access_ssh` refuses an account before its key is read. Read the group — `dscl . -read /Groups/com.apple.access_ssh` — and read both `GroupMembership` and `NestedGroups`, which are separate lines; a pattern matching only one reports the group empty when it is not.

**Roles answer a different question than permissions.** An ownership map says who is accountable for a domain, not who holds the specific permission a task needs. Ask what permission this specifically requires and who is *known* to hold it, then check rather than infer. Record what was observed separately from what was assumed; the second decays into the first.

## 4. Identifier hygiene while checking

Most false negatives here come from the query, not the system.

- **Match key material, never a comment.** An `authorized_keys` comment is free text chosen by the key holder. A key commented with a personal address can be byte-identical to the work key beside it. Compare with `ssh-keygen -l -f` and match fingerprints.
- **Anchor greps, and treat an empty result as evidence about the query first.** A short tag matches inside ordinary words; a listing that omits the target may be the wrong index. Before reading nothing as absence, run `audit-the-instrument` on it.

## 5. Report the ladder, not just the answer

Say which gate refused, and **name the gates that were not checked**. A diagnosis reporting only the found cause invites the reader to assume the rest were verified.

When a change closes some gates but not all, state which remain — "access granted" must not read as "they can connect" while a shared credential handoff is still outstanding. If a grant is applied but never confirmed against live state, say so plainly rather than letting the apply stand in for verification.

## Boundary

- **A network-reachability check** answers "does the packet get there at all" — routing, a VPN or connector, a firewall. Use one when nothing answers. Use this skill when a request arrived and was *refused*, on any system.
- **Designing a grant** — deriving least privilege from what a principal is observed to do — is the inverse job and is not this skill. This one starts from a refusal that already happened.
- **A service that is down is not a denial.** A connection refused with nothing listening, or a process that is not running, is an availability problem; confirm the thing is up before walking the authorization ladder.

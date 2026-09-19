---
name: handle-a-found-credential
description: This skill should be used when a live credential turns up somewhere it should not be — a token in launch-template user_data or a config file, an API key in a build log, a password in a repo or a Jenkins job, an undocumented key on a seized account — to bound the exposure before acting on it. Enumerates at the identity rather than the discovery surface, reads the scopes as the blast radius, captures evidence before an irreversible revoke, revokes the credential and the standing separately, and redacts by region so the report is not the second disclosure. Produces what the credential reached, an ordered revoke-and-clean sequence, and what can no longer be answered. Triggers "there's a token in this config", "found a hardcoded secret", "this key is in plaintext", "how bad is this exposure", "what can this token actually reach", "what's the blast radius of this key", "how do I report this without leaking it again". Distinct from `scope-a-grant-from-observed-use` (DESIGNS a grant forward — this asks what an existing secret reaches, not what it should), `diagnose-denial` (a refusal; here the credential still works), `security-review` (reads a diff, never touches a live secret) and `audit-the-instrument` (a suspect verdict). NOT for choosing a secrets manager, NOT for a credential already rotated and confirmed dead, and NOT for speculative scanning when nothing has been found.
version: 1.0.1
summary: Bound the exposure when a live credential turns up where it should not be — enumerate at the identity, read the scopes as the blast radius, capture evidence before revoking, separate credential from standing, and redact by region so the report is not the second leak.
---

# handle-a-found-credential

A credential has turned up somewhere it should not be. The urge is to revoke it immediately, and that urge destroys the only evidence of what it could reach. The urge after that is to write it up, and the write-up is where it leaks a second time.

Both failures come from treating the **discovery** as the thing to act on. It is not. The discovery is one sighting of an identity whose reach is still unknown, and the work is to bound that reach before touching anything irreversible.

## 1. Enumerate at the identity, not at the discovery surface

"Which credentials did we find in the compromised place" and "which credentials exist on this identity" are different questions, and only the second bounds the risk. The first answers with what happened to be visible.

Ask for the identity's whole credential list at its own authority — the account's token page, `aws iam list-access-keys` for the user, the app's key list, `authorized_keys` on every host it can reach — not just the one place the finding came from.

Expect the count to be wrong in the unsafe direction. A record saying "one token on this account" is a **floor**, not an inventory: it means one was found once, and it says nothing about what else was minted since. Treat a number that came from a document as a lower bound until re-read live.

State the population you covered, and the one you did not. "No other keys" is only a finding if you can name where you looked and what would have shown a key you missed.

## 2. Read the scopes — they are the blast radius

Location is not impact. "A token in a bad place" describes storage; the scopes describe what an attacker holding it can do, and the two routinely disagree by an order of magnitude. A credential filed for two years as a build token can carry organisation-admin.

One call usually answers it, and it should happen before any severity is stated:

- A token: the identity endpoint, reading the returned scope header.
- An AWS key: the attached and inline policies of its principal — both, because an inline policy can undo a managed policy's exclusion.
- An app or service account: its granted permissions and the resources it is installed on, which is often wider than the request that created it.

Two things change the ranking more than the scopes themselves. **What routinely executes where the credential sits** — a host that runs untrusted pull-request builds is an execution path anyone with pull-request rights can drive, and storage stops mattering. And **who else can already reach the same thing by another route**, because a scary-looking grant that duplicates an existing team permission changes the remediation and not the exposure.

## 3. Capture the evidence before revoking

Revocation is irreversible and takes the evidence with it. Name, scopes, created date, last-used, what it is installed on — one screenshot's worth, captured while the access is in hand.

This is the step that gets skipped under time pressure, and the cost is permanent: a credential revoked before its scopes were read leaves "what could it reach" unanswerable forever, which then blocks every later question about whether the incident is closed.

Check specifically for what the platform will stop telling you once the moment passes. Some providers offer no way to list an account's own tokens, no user-level security log, and no session list; on smaller plans there may be no organisation audit log either. If "was it actually used?" matters, it must be answered now, in the interface, while someone holds the account.

Capturing first costs seconds. Sequence it that way unless the credential is actively being abused, in which case revoke and say plainly in the write-up which evidence was traded away for speed.

## 4. Revoke the credential and the standing separately

Authentication and authorization fail at different gates, and only the first names itself in an error. Revoking the key that produced the error message may leave the identity's standing untouched — still a member of the group, still a collaborator, still assigned the role.

The reverse also holds, and is the one that gets missed: removing the direct grants a record names can change **nothing**, because the same access arrives through a team or group membership that nobody listed. Containment then closes the grant the record named and not the route.

So enumerate both, and **measure** the result rather than reading it off the change you just made. Two controls make an effective-permission read trustworthy: check whether an organisation-wide default is supplying the access independently, and check whether the identity is a direct collaborator or only an indirect one. Without them, a permission that survives looks identical to a permission you removed.

## 5. Ask who can modify the code that reads it

Before asking where the secret should live, ask who can edit the thing that consumes it.

Moving a secret into a secret store defends against **accidental** disclosure — it stops the value appearing in a config file, a diff, or a log. It does not defend against a person. Anyone who can edit the job, pipeline, or function that reads the secret can print it in a form masking will not recognise: base64, reversed, split across lines, written to an artifact.

So if the population that must not read the secret overlaps the population that can edit its consumer, "move it to a secret store" is not remediation. That leaves two coherent end states:

- **Narrow the edit right** off the population that should not have the secret, or
- **Remove the static credential entirely** — an instance role, workload identity, or short-lived assumed credential — which also converts an unanswerable "who could have read this" into an auditable "who ran what".

Say which of the two the recommendation is. A remediation that only relocates the secret should be labelled as reducing accident, not exposure.

## 6. Redact by region, never by variable name

The report is the second place this can leak, and a name-based redaction filter fails open silently.

A mask keyed on secret-looking names — `PASS`, `SECRET`, `TOKEN`, `KEY`, `CRED` — hides every value whose name is on the list and prints in full every value whose name is not. `SLACK_HOOK_URL` is not on that list. Extending the list is the same bug with a longer list, and the asymmetry is what makes this class dangerous: an over-aggressive mask is noisy and announces itself, while a too-narrow one is invisible and its output *looks* handled.

Redact the **region** a comment or a schema marks as credentials, or print only shapes — length, character class, first four characters of a key id — never values. When quoting a config block, quote its structure and elide the block wholesale.

The same reasoning applies to gathering. Never build an allowlist by pattern-matching a channel, thread, ticket, or mail folder: an incident thread contains the attacker's key alongside everyone else's, and a sweep cannot tell them apart. Build from an explicit list of named keys, one line per person you can name, and assert the known-bad fingerprint is **absent** as a printed check in the same step.

## 7. Report

State each of these, and mark the ones you could not answer:

- **What it reaches** — the scopes, and the resources they apply to, measured rather than inferred.
- **Who could have read it** — the population with read or edit access to where it sat, and whether that is auditable at all.
- **How long** — created date against the earliest exposure, which is often the file's mtime.
- **What was revoked, and what standing remains** — the two as separate lines, each measured after the change.
- **What can no longer be answered**, because something was revoked or deleted before capture. Name it explicitly; a gap that is not stated reads as a clear finding.
- **Whether the remediation removes the exposure or only the accident** (§5).

Expect fallout and say so up front. A credential nobody can account for may be load-bearing for automation nobody has identified, and that breakage will look unrelated to anyone who was not told an unknown credential was killed.

## Not this skill

- Nothing has been found yet, and the ask is to go looking — that is a scanning task, and a codebase-wide sweep is `security-review`'s ground.
- The credential is already rotated and confirmed dead, and the question is where secrets should live going forward — that is design, not exposure handling.
- The question is why an access request is being **refused** — the credential works here, which is the whole problem. Reach for `diagnose-denial`.
- The question is what a principal *should* be granted, derived from what it does — `scope-a-grant-from-observed-use`.

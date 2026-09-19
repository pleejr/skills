---
name: settle-what-governs-an-attribute
description: This skill should be used when a Terraform question comes back to what actually owns a field — a diff that keeps returning, a plan reporting no changes while the rule is still live, a resource in state with nothing declaring it, a console edit that vanished, a cleanup inventory grepped out of `.tf` files, a provider bump that wants to delete something, or a cron about to write a field something else already writes. Reads config, state and live as three separate answers rather than one, enumerates every writer of the field from the API rather than the repo, and names the single owner. Use it even when the config reads unambiguously and the plan is clean — both agree with the mistake. Triggers: "will this apply revoke those rules", "why does this diff keep coming back", "I deleted the block but the plan says no changes", "this resource is in state with nothing declaring it", "what else writes this tag", "the console change disappeared", "is grepping the tf files enough for this inventory", "is it safe to import this", "why does the bump want to delete that". Distinct from `read-the-plan-before-the-apply` (reads plan OUTPUT against a stated expectation), `blast-radius-before-a-shared-change` (consumers of a shared module) and `verify-the-change-is-in-effect` (a change already ACCEPTED). NOT for sorting Terraform config, NOT for reviewing a pull-request diff.
version: 1.0.0
summary: Read config, state and live as three separate answers and enumerate every writer of a field before claiming what an apply will do to it.
tags: [infra, terraform]
---

# settle-what-governs-an-attribute

Configuration reads as authoritative and usually is not the whole answer. Before saying what an apply will do to a field — or building an inventory, or importing a resource, or shipping something that writes one — settle two questions: **which of config, state and live is the provider actually enforcing**, and **what else writes this field**.

Both failures run in the reassuring direction. The config is in the file, the diff looks right, the plan is clean, CI is green. Nothing contradicts the mistake except live state, which nobody re-reads after a plan says `No changes`.

## 1. Three readings, never one

`config`, `state` and `live` answer different questions, and any two of them can disagree indefinitely.

| Reading | Command | What it answers |
|---|---|---|
| **config** | `git show origin/main:<path>` | what the repo declares |
| **state** | `terraform state show <addr>` | what Terraform believes it manages |
| **live** | `aws <svc> describe-* ` / the vendor API | what is actually running |

Read the **whole resource block to its closing brace**, including `lifecycle`. Then read state, then live. The comparison that identifies the mechanism:

- **state matches live, config disagrees** → the attribute is **ignored**, not drifted. Look for `lifecycle { ignore_changes = [...] }`, usually a few lines below the block you grepped. Its neighbours normally carry it too.
- **state holds it, live does not** → residue, not a pending destroy, if the object was deleted outside Terraform. `Drift detected (delete)` in the log with `0 to destroy` in the summary is the signature; a `delete` under `planned_change` is a real destroy.
- **live holds it, config is silent** → the provider never sends the field (`Optional + Computed`), so it persists and reports no drift. A provider upgrade that narrows the handling turns the same unchanged config into *remove it*, in every environment at once.
- **config removed the block, plan says `No changes`** → with no blocks at all the provider reads the attribute as *not configured*, not *configured empty*. `ingress = []` — attribute syntax — plans the revoke; deleting the blocks does not.

## 2. The writer census

Any field with two writers is silently reverted by whichever writes next, and the loser's own logs show a correct-looking `updated` every cycle. **Split ownership by field is legitimate; shared ownership of one field is not.**

Enumerate writers from the API, not the repo. The recurring pairs:

| Second writer | What the loser sees |
|---|---|
| Platform autoscaler vs a cron | capacity oscillating, every cycle logging success |
| `aws_autoscaling_schedule` vs ASG literals | outside the window every apply plans a scale-up nobody asked for |
| A workflow deploy vs a Terraform-managed `:latest` | the next apply restores the old image, with no address outside the expectation |
| A console edit vs a whole-document resource | the edit is consumed by the next unrelated apply, leaving nothing in state |
| `aws_ec2_tag` vs a module that sets `tags` | the tag is stripped by an unrelated plan in the same account |
| An operator's lever vs an import program | a later apply re-enables a mode a human turned off in production |
| Two systems keyed on one string | renaming the principal strands every grant that named it |
| Provider default vs an attribute never declared | a routine version bump plans a deletion in every environment |

Then name one owner, explicitly: declare the field where the resource is declared, or `ignore_changes` it and say who owns it instead, or leave it unmanaged **deliberately** and write the exclusion down where the value lives. A value that is declared but ignored is worse than no declaration, because it invites exactly this misreading.

## 3. Retire an out-of-band writer in three steps

Deleting the block calls the delete API and physically strips the value, with the other manager re-adding it on some later apply; ordering inside one apply is not guaranteed.

1. Declare it in the new place and apply.
2. Drop the old resource from state with a `removed` block carrying `lifecycle { destroy = false }`.
3. Delete the spent block.

Read the live value back between steps.

## 4. Inventories are built from the running system

For any cleanup whose subject is a live thing — a firewall rule, a database role, a DNS record, an IAM grant — enumerate **live** first and state the population the query covered. Use the repo only to find where the change goes.

A declaration-based inventory can be wrong in both directions at once, and the two errors hide each other: it lists rules that do not exist, which makes the ticket look urgent and complete, and omits the ones that do, which were the only thing worth doing. A reviewer checking the ticket against the repo confirms it perfectly.

When a config item is absent from live, look for `ignore_changes`, a `count = 0`, a module not in the workspace, or a resource never applied, before concluding the sweep is broken. Expect unmanaged resources — a Terraform-shaped plan cannot see what appears in no `.tf` file.

## 5. What to report

1. **Which reading** the claim rests on — config, state or live — named, not implied.
2. **The mechanism**, if config and live disagree: ignored, undeclared, unmanaged, or genuinely drifted.
3. **Every writer found**, and which one owns the field now.
4. **What was not checked**, as a gap.

## Rules

- Read config from `origin/main` after a fetch, never from a working tree.
- One live `get-*` / `describe-*` call separates residue from a real resource, and it is the same call either way.
- An unexpected address in a plan is a question about what else owns it, not noise — hand it to `read-the-plan-before-the-apply`.
- A module-wide tag input spreads to every resource the module merges it into. Inert, but it dilutes what the tag means, so say so where the tag is defined.
- When handing someone a console workaround, say out loud that it expires at the next apply.

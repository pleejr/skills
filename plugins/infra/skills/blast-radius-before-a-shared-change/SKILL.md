---
name: blast-radius-before-a-shared-change
description: This skill should be used before changing something other things consume — a Terraform module, a shared GitHub Actions workflow, an upstream data producer — to enumerate the live consumers FIRST, while the change is still being designed. Sweeps the resource type the module CREATES rather than its source string (a copier reads as `defines>0 && calls==0`), counts root-module instantiations per environment rather than `module` blocks in source, asks what the new feature's ABSENCE renders as, and checks whether the consumers' pins float. Produces a consumer inventory with per-environment counts plus an explicit list of what the sweep could not see. Triggers: "who uses this module", "what will this break", "is this change backwards compatible", "it's additive so it's a no-op right", "before I release this module version", "who consumes this workflow", "how many call sites are there", "what is the blast radius of this change", "is it safe to add this field", "what reads this table", "can I pause this job", "will this reach prod". Distinct from `read-the-plan-before-the-apply`, which gates ONE workspace's plan after the change already exists — this runs before the change is written, across consumers. NOT for scoping a permission grant (`scope-a-grant-from-observed-use`), and NOT for confirming a released change went live (`verify-the-change-is-in-effect`).
version: 1.0.0
summary: Enumerate the live consumers of a shared thing before changing it — sweep the resource type rather than the module source, count root-module instantiations per environment, ask what the feature's absence renders as, and check whether the pin floats.
tags: [infra, terraform]
---

# blast-radius-before-a-shared-change

Establish who consumes a shared thing **before** writing the change to it. The subject varies — a Terraform module, a wrapper over one, a reusable workflow consumed `@main`, an Airflow DAG whose tables other DAGs read — and the procedure does not.

The failure this prevents is not a bad change. It is a correct change whose reach was never measured: a module release that narrowed IAM on **20 services across nine wrappers and eleven call sites** when the ticket described six, surfacing as unexplained destroys in two other sessions' plans; a CI gate merged to a shared workflow's `@main` where **38 consumer repos** pick it up, reverted within the hour. Both were authored carefully. Neither had an inventory.

The inventory has to exist before the diff, because after the diff every question about scope is answered by looking at what was written rather than at what consumes it.

## 1. Name the shared thing, and what it creates

Write down two things:

- The **address consumers use** — `app.terraform.io/<ORG>/<MODULE>/aws`, `<org>/workflows-terraform-ci/.github/workflows/terraform.yml@main`, `<schema>.<table>`.
- The **resource type or artifact it produces** — `aws_ecs_service`, `aws_iam_role_policy`, the Redshift tables the job loads.

The second is the one that finds consumers the first cannot see.

## 2. Sweep the resource type, not the source string

A grep for the module source finds every repo that **calls** it and none that **copied** it. A copier is invisible twice — absent from the consumer inventory *and* absent from the list of sites still missing the fix — so it reads as compliant.

```bash
# what actually defines the resource (finds callers AND copiers)
git -C "$d" grep -l -E 'resource "aws_ecs_(service|task_definition)"' origin/main -- '*.tf'
# what calls the module (callers only)
git -C "$d" grep -l 'ecs-service/aws' origin/main -- '*.tf'
```

`defines>0 && calls==0` is the finding. On 2026-08-24 that sweep, run only in its `calls` form, missed `terraform-aws-module-scraper`, `infra-aws-tf-ww-qa/service_core_qa.tf` and `infra-aws-tf-ww-prod/aws_ecs.tf`.

Two rules that keep the population honest:

- **Read from `origin/main`, never the working tree.** Local clones are stale, and a release reaches every open branch, not just the default one. Sweep remote branch refs when the change ships through a floating pin (§5).
- **Dedupe by remote before counting.** A second clone of one repo double-counts and invents a repo — `tf-mod-tailscale-via-dst` is a clone of `terraform-aws-module-tailscale-server`, and it turned a correct 154-across-22 into a wrong 161-across-23. Check `git remote get-url origin` per directory.

Same exposure is not the same prescription. `infra-aws-tf-ww-prod/aws_ecs.tf` carried the same six wildcard log actions as the module, but as an imported RDS-oriented policy whose consumers are not ECS task roles; narrowing it would have broken an RDS log export. List each site's own shape, not just its presence.

## 3. Count root-module instantiations, not `module` blocks

A `module` block inside a wrapper that nothing instantiates is **zero live call sites**. Counting references in source produced "14 call sites across 12 module repos" where the live count was nine: five `terraform-aws-module-core` services were reachable from exactly one file, `infra-aws-tf-ww-qa/service_core_qa1.tf`, and nothing in prod calls `core/aws` at all — those services are hand-written there. The row promised a module fix would reach prod services it could never reach.

Two hops:

```bash
# hop 1 — who references the shared module
git -C "$d" grep -l '<shared-module>/aws' origin/main -- '*.tf'
# hop 2 — is that wrapper itself invoked, and from where
git -C "$d" grep -n '<wrapper-module>/aws' origin/main -- '*.tf'
```

Report **per environment**. Where a wrapper is invoked in qa and not in prod, that belongs in the row, not in a footnote — it is the difference between a fix that reaches production and one that does not.

While at hop 2, check the surfaces differ: a `precondition`, `validation` or `lifecycle` guard exists only in the module where it was written, and a base variable is reachable from a consumer only if the wrapper forwards it. A never-forwarded input is silence, not an error, and no plan shows it.

```bash
git -C terraform-aws-module-<wrapper> show origin/main:variables.tf | grep -c '<var>'
```

## 4. Ask what the feature's ABSENCE renders as

An additive input is a no-op for existing consumers **only when its absence renders as absence**. The obvious implementation sets the new key unconditionally and lets it be empty:

```hcl
main_container = {
  mountPoints = local.efs_mount_points   # [] when no volumes
}
```

That reads as inert and is not. `container_definitions` is `jsonencode`d, so `"mountPoints":[]` is a different string from no key at all — a new task-definition revision, and a redeployment of every service on the module that asked for no volumes. Merge the key in instead, so it is absent when unused:

```hcl
main_container = merge(local.main_container_base, local.efs_enabled ? {
  mountPoints = local.efs_mount_points
} : {})
```

The trap is any attribute the provider compares as an **opaque serialized blob** rather than field by field: `jsonencode`d policy and container documents, `user_data`, templated config bodies. There an added empty key, a reordered map or a whitespace change all read as a real diff.

**Measure it, and the measurement needs the negative case.** Run `jsonencode(before) == jsonencode(after)` against the real expressions and report both rows — `true` with the feature off, **`false` with it on**. A comparison that answers "identical" to both is measuring nothing.

The sibling shape is a new variable that splits two meanings one variable carried: every untouched reader of the old variable is now reading the wrong one, and nothing fails, because a stale reader still returns a valid number — no null, no type error, no plan-time failure, no diff entry. `ecs-service` v4.8.0 added `task_min_count` for the autoscaling floor while the `task_count` alarm in another file kept `threshold = var.task_desired_total_count`; a production service ran with a floor of 6 and an alarm firing below 3, blind to losing half its fleet, for twelve days. Before opening the PR, grep the whole module for the **old** variable and decide per hit which meaning it wanted.

## 5. Check whether the pin floats

A floating pin turns a release into a fleet-wide change that arrives with no commit, no PR and no notification in any consuming repo — at whatever moment each consumer next runs.

```bash
# consumer constraint shapes
git -C "$d" grep -n 'version = "~> ' origin/main -- '*.tf'
```

Enumerate consumers **by constraint shape**, transitively. Consumers frequently pin the wrapper exactly and float on the base — `~> 4.0`, `>= 4.5.2, < 5.0.0`, `>= 4.8.1, < 5.0.0` — and child versions resolve at `terraform init` on every run, so a base release moves resources in four workspaces with no diff anywhere. The same shape in CI is an action or workflow consumed `@main` or a tool resolving `latest`.

Name both costs before choosing minor versus major: a **major** cannot reach a floating consumer (`~> 2.0` will not cross to 3.0.0), so it stays inert until every caller bumps; a **minor** lands estate-wide at once, open branches included.

Settle "what will this constraint resolve to" with a probe rather than an argument:

```bash
mkdir /tmp/probe && cd /tmp/probe
cat > main.tf <<'TF'
module "probe" {
  source  = "app.terraform.io/<ORG>/<MODULE>/aws"
  version = ">= 4.8.1, < 5.0.0"     # the constraint under test, copied verbatim
}
TF
terraform get                        # modules only — no provider download, no backend init
grep -r '<the attribute you changed>' .terraform/modules/probe/
```

`terraform get` fetches and stops, so a config missing required variables still downloads the module. Read the resolved content directly; `modules.json` is not written when the run errors. One block per constraint shape answers the whole fleet.

## 6. Non-Terraform consumers: the producer case

Pausing or changing a producer moves the blast radius **downstream**, and the scheduler does not know the dependency. Grep the deployed bundle for the schemas and tables the producer writes, and list what reads them:

```bash
grep -rEn 'from|join[[:space:]]+<schema>\.<table>' <deployed-dag-bundle>/
```

Seven paused extract DAGs left `braze_tags_hourly_dag` (`30 * * * *`) and `braze_usernames_hourly_dag` (`05 * * * *`) unpaused and reading exactly the tables the paused jobs load — a wrong-audience customer send, not a failure, which is harder to notice and harder to explain. Cross-schedule matters as much as the dependency: two consumers at `:05` and `:30` fire inside any window longer than half an hour.

Ask which producers are **diff-based** rather than watermark-based. A watermark producer widens its next window and loses nothing; a producer computing deltas against a snapshot of its previous load loses any event that appears and disappears inside the gap, permanently, and no later run recovers it.

## 7. Report the inventory, and what it could not see

```
Shared thing: <address consumers use> — creates <resource type / artifact>
Consumers:    <site> — <calls | copies> — <environments> — <constraint shape>
              ...
Per env:      qa <n>, prod <n>   (root-module instantiations, from origin/main)
Absence:      <what the disabled path renders as; both measurement rows>
Pin:          <exact | floating: which consumers, which shape>
Not covered:  <populations the sweep did not reach>
```

The last line is not optional. Name the branches not swept, the repos not cloned, the environments where the wrapper is not invoked, the consumers reached only through a floating pin. An incidental count is a lower bound, not a measurement: three instances tripped over while doing something else became 154 across 22 repos when measured with a denominator.

## 8. What the inventory then decides

- **Zero live consumers** — the change is free; say so and move on.
- **One live, validated consumer and a second arriving** — ship a copy rather than promoting to a shared module. The cost is not duplication, it is that promotion changes the resource address to `module.<name>.<type>.this`, which Terraform reads as destroy-plus-create of the thing that already works unless every address is covered by a `moved` block. Promote at a third consumer, or when the first is being touched anyway.
- **Many consumers on floating pins** — the release *is* the deployment. Say so in the release notes, and drain the latent diff by applying the owning ticket's workspace first so sessions behind it re-plan clean.
- **Consumers you could not enumerate** — that is a stop, not a caveat.

Then hand off: the inventory says what the change reaches, and `read-the-plan-before-the-apply` gates each workspace's plan once the change exists.

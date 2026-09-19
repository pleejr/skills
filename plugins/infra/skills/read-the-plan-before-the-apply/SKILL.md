---
name: read-the-plan-before-the-apply
description: This skill should be used before confirming any Terraform apply — to check what a plan actually changes by reading its resource ADDRESSES, and the before/after attributes of every update, against an expectation written down BEFORE the plan was opened. Produces a gate verdict — proceed, or stop and report the address that was not predicted. Use whenever an apply is about to be authorized, a plan returns more changes than expected, a change count needs explaining, or an "unrelated" resource appears in a diff. Triggers: "is this plan safe to apply", "should I apply this", "the plan has more changes than I expected", "what is this plan actually going to do", "why is that resource in the plan", "read the plan", "gate this apply", "check the blast radius of this plan", "confirm and apply", "is this a no-op", "the plan says 3 to change", "what does this destroy", "this policy document diff is unreadable". Distinct from a run-status check (which reads a run's STATUS and never opens the plan body — the wrong signal to authorize on) and from `scrutinize` (critiques a written plan document, not plan output). Distinct from `blast-radius-before-a-shared-change` (consumers, before the change exists). NOT for sorting Terraform config (`safe-tfsort`), NOT for deciding whether a run has finished, and NOT for reviewing a pull-request diff — this reads what the provider says it will DO.
version: 1.0.2
summary: Gate a Terraform apply by diffing the plan's resource addresses — and each update's before/after attributes — against an expectation stated before the plan was opened. Any unexplained address is disqualifying.
tags: [infra, terraform]
---

# read-the-plan-before-the-apply

Decide whether a Terraform plan may be applied, by comparing what it says it will do against what you predicted it would do — **in that order**. The prediction has to exist first, because a plan read without one is not checked against anything; it is merely read, and a plan that looks reasonable is the normal appearance of a plan that reverts someone else's work.

The subject varies — module, workspace, account, provider. The procedure does not.

## Why the ordering is the whole mechanism

Writing the expectation down after seeing the plan is not a weaker version of this check. It is not the check at all. Plan output is persuasive: every address in it has a plausible story, because Terraform only proposes changes its graph genuinely implies. The question "is this reasonable?" almost always answers yes. The question that discriminates is "is this what I said would happen?", and that one can only be asked if the answer was recorded while it could still be wrong.

So: **state the expectation, then open the plan.** If a plan is already open and no expectation was recorded, the honest move is to say so and predict from the source diff before reading further — not to reconstruct a prediction from what you have just seen.

## 1. State the expectation

Before opening the plan, from the source change alone:

- Every resource **address** you expect to appear, spelled out — `module.opsbot_dev.aws_cloudwatch_metric_alarm.elb_5xx[0]`, not "the alarm".
- The **action** for each — create, update, replace, destroy.
- For updates, **which attributes** should move. This is where a stated expectation earns most of its value: "3 to change" is exactly the shape in which a prediction quietly fails.
- The totals, as a consequence of the above rather than as the prediction itself.

Say it out loud to whoever authorizes the apply. An expectation held privately is not auditable, and the point of the gate is that someone else can see it held.

## 2. Read addresses, never counts and never status

Change counts are a summary of the thing you need, not the thing. Two plans with identical `+0 ~2 -0` counts can touch entirely different resources.

**Run status is worse than useless here**, and this is the trap worth naming: a plan-only (speculative) run — every pull-request check plan — always settles `planned_and_finished`, whatever it contains. A speculative plan with 40 destroys is indistinguishable by status from one with zero changes. `planned_and_finished` means "0-change no-op" only on a **regular** run, which is what makes the misreading plausible.

Pull the structured plan and filter to real actions:

```bash
# Reach it by RUN id — a `run-…` URL is what CI hands you; both forms 307-redirect
# to blob storage, so -L is required or the body is empty.
curl -sL -H "Authorization: Bearer $TOK" \
  "https://app.terraform.io/api/v2/runs/<RUN_ID>/plan/json-output" -o plan.json

python3 -c '
import json,sys
d=json.load(open("plan.json"))
for rc in d.get("resource_changes",[]):
    if rc["change"]["actions"] != ["no-op"]:
        print(rc["change"]["actions"], rc["address"])'
```

Locally, `terraform show -json tfplan` produces the same document.

## 3. For every update, diff before against after

An address list cannot tell you whether an update recycles a task, rotates a credential, or moves one threshold. Flatten and compare:

```bash
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
def flat(x,p=""):
    if isinstance(x,dict):
        for k,v in x.items(): yield from flat(v,f"{p}.{k}")
    elif isinstance(x,list):
        for i,v in enumerate(x): yield from flat(v,f"{p}[{i}]")
    else: yield p,x
for rc in d["resource_changes"]:
    if rc["change"]["actions"]==["update"]:
        b=dict(flat(rc["change"]["before"])); a=dict(flat(rc["change"]["after"]))
        print("==",rc["address"])
        for k in sorted(set(b)|set(a)):
            if b.get(k)!=a.get(k): print("   ",k,":",b.get(k),"->",a.get(k))' plan.json
```

This is what turns "3 target groups change" into "only `health_check.timeout` moves, so no task is recycled" — a difference worth approving on, which the address list alone cannot show.

**`after_unknown` marks values the plan could not resolve.** An attribute appearing only there is **unverified**, not unchanged. Never report it as "no change".

### When the attribute IS the whole resource — parse it, never diff it as text

Some resources hold their entire state in one string attribute containing a document: an ACL, a bucket or key policy, an IAM policy document, a dashboard body, most `*_policy` resources. There the flattened before/after above degenerates into a single enormous pair, and a textual diff is close to useless — **providers re-serialise the document, so the text diff is mostly reformatting** (a one-member ACL change produced a 211-line diff).

Both shortcuts available at that moment are wrong, in opposite directions:

- approve because the **count** said `1 to change` — that never read the attributes, which is what the gate turns on
- refuse because the **diff looked enormous** — that is a reaction to the serialiser, not to the change

Parse both sides and report one line per **structural** difference:

```bash
python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
def walk(p,x,y,out):
    if type(x)!=type(y): out.append((p,x,y)); return
    if isinstance(x,dict):
        for k in sorted(set(x)|set(y)):
            if k not in x: out.append((p+"."+k,"<absent>",y[k]))
            elif k not in y: out.append((p+"."+k,x[k],"<absent>"))
            else: walk(p+"."+k,x[k],y[k],out)
    elif isinstance(x,list):
        if len(x)!=len(y): out.append((p,x,y))
        else:
            for i,(u,v) in enumerate(zip(x,y)): walk(p+"[%d]"%i,u,v,out)
    elif x!=y: out.append((p,x,y))
for rc in d["resource_changes"]:
    if rc["change"]["actions"]!=["update"]: continue
    for attr in ("acl","policy","policy_document","dashboard_body","body"):
        b,a=(rc["change"]["before"] or {}).get(attr),(rc["change"]["after"] or {}).get(attr)
        if not (isinstance(b,str) and isinstance(a,str)): continue
        out=[]; walk("",json.loads(b),json.loads(a),out)
        print("==",rc["address"],attr,"|",len(out),"structural difference(s)")
        for p,x,y in out: print("   ",p,"\n      before:",x,"\n      after: ",y)' plan.json
```

State that structural count in the verdict — "one structural difference, `groups.group:X` 4 → 5 members" is approvable; "211 diff lines" is not. If the document is HuJSON or otherwise not plain JSON, strip comments before parsing rather than falling back to the text diff.

**Two things this buys beyond readability.** First, a genuine second change hidden among 200 reformatted lines is invisible to the eye and obvious to the walk. Second, when the run has `refresh: True`, `before` **is** the refreshed live document — so a walk returning only your intended change is also evidence that nothing was added outside the configuration. That matters because an apply of a whole-document resource **overwrites** anything console-added, silently. It is inference from a refreshed plan rather than a direct read, so say which it is; but it is often the only check available when the provider credential exists solely as a remote-workspace variable.

## 4. Triage every address you did not predict

An unpredicted address has more than one cause, and they have opposite correct responses. Work through them before concluding anything:

| What you see | Likely cause | How to tell | Response |
|---|---|---|---|
| A resource nothing in your diff touches, `after_unknown` on its computed attributes | **Deferred data read** — a data source depending on a pending change is read at apply time, so every consumer is listed as an update | `after` absent, attribute in `after_unknown`; nothing the document actually reads has changed | Graph artifact; explain it explicitly, do not silently ignore it |
| A change that looks like console drift, on a drift-prone resource, reverting something plausible | **Your branch is older than the last apply** — the plan faithfully proposes to revert what landed since | Check the merge-base; rebase and re-plan | Rebase. Applying would silently revert someone's deliberate change |
| A resource you believe is already correct, planning clean | **A no-op cannot prove resource type** — where two resource types wrap one API object and the describe call is type-agnostic, the type is never compared | Look for an attribute that a real instance of the declared type must have and that is empty | A clean plan cannot answer that question; check the live object directly |
| An empty authoritative collection rejected at apply | **The API refuses `[]`** on membership/attachment resources rather than asserting emptiness | Fails at apply, not plan | Do not treat a clean plan as proof the apply will succeed |
| Nothing at all, on an import or a client-side op | **Every provider in the configuration is configured**, not just the one that owns the resource | A credential error naming a provider the operation never touches | Supply the unrelated provider's credentials |

If none of these explains it, the address is unexplained. That is the disqualifying case.

## 5. The verdict

**One unexplained address turns the whole plan back into stop-and-report.** Not the one address — the plan. A prediction that was wrong once has no standing to vouch for the addresses that happened to match.

Report in this shape:

```
Expected: <addresses + actions, as stated before the plan>
Plan:     <+N ~N -N>, addresses:
            <action> <address>   [predicted | explained: <cause> | UNEXPLAINED]
For updates: <attribute> : <before> -> <after>
Verdict:  proceed | stop — <the address that was not predicted>
```

Then apply, or stop. Do not narrate a verdict of "mostly as expected".

## 6. What this gate does not cover

- **It does not make an irreversible change safe.** The address diff establishes *what* changes, never whether the change can be backed out. Deleting production data, releasing an address, destroying an identity, or overwriting with no saved prior version needs a human decision regardless of how cleanly the plan matched.
- **A clean plan is not a successful apply.** Section 4 lists two failures that appear only at apply time.
- **It reads the provider's intent, not the world.** After applying, verify live state with `verify-the-change-is-in-effect` — a plan can be predicted correctly, applied successfully, and still change nothing, because the acknowledgment and the running system are different surfaces.

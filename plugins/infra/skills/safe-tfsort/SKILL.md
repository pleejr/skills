---
name: safe-tfsort
description: This skill should be used when sorting Terraform variables/outputs with tfsort, or when updating a Terraform module's variables.tf/outputs.tf. Wraps tfsort to alphabetically sort variable/output blocks WITHOUT losing comments — tfsort >=0.7.1 silently drops standalone and commented-out blocks, so use this instead of bare tfsort. Triggers: "sort variables", "run tfsort", "tfsort the variables file", "sort the module variables".
version: 1.0.1
summary: Wraps `tfsort` to alphabetically sort Terraform `variable`/`output` blocks without ever dropping comments or commented-out blocks (bare tfsort ≥0.7.1 silently loses them).
---

# safe-tfsort

Alphabetically sort Terraform `variable`/`output` blocks **without ever losing content.**

## Why this exists

`tfsort` (>=0.7.1) sorts blocks correctly but **silently deletes** content it can't
attach to a retained block — commented-out `variable` blocks, section-header comments,
and other standalone trivia. It has been observed stripping intentional commented-out
placeholder blocks from a module's `variables_*.tf`. Bare `tfsort` is therefore unsafe
to run unattended on real modules.

## The guarantee

**Content is never lost at the cost of sorting.** A file is written only if every
non-blank line of the original is preserved *and* the result is valid HCL. The wrapper:

1. Runs `tfsort` on a temp copy (the real file is never touched until the end).
2. If tfsort's output preserves all content → writes it (canonical format).
3. If tfsort dropped content → reconstructs a file using tfsort's **order** but each
   block's **original leading comments**, so a dropped comment travels with the block
   it preceded (its owning block).
4. Re-verifies the reconstruction (a) loses no non-blank line and (b) is valid HCL
   (`terraform fmt` when available, else a brace-balance check).
5. If it still can't guarantee a lossless, valid sort → **reverts** (leaves the file
   untouched) and reports the unrecoverable lines.

## How to use

Run the wrapper on the variables/outputs files. It accepts multiple paths.

```bash
S="$(readlink ~/.claude/skills/safe-tfsort)/scripts/tfsort_safe.py"   # the symlink is the pointer; the checkout path differs per machine

# Preview without writing:
python3 $S --dry-run path/to/variables.tf

# Sort in place (only writes when safe):
python3 $S path/to/variables.tf path/to/outputs.tf
```

Across many module repos:

```bash
find . -maxdepth 3 -type f \( -name 'variables*.tf' -o -name 'outputs*.tf' \) -print0 \
  | xargs -0 python3 $S
```

## Reading the output

| Status | Meaning | Action |
|--------|---------|--------|
| `ok` | already sorted | none |
| `sorted` | tfsort sorted it losslessly | none |
| `restored` | tfsort would have dropped comments; they were reattached and preserved | review the recovered comments landed sensibly |
| `REVERTED` | could not sort without losing content or producing invalid HCL; **file left unchanged** | tell the user, show the listed lines, and sort by hand if needed — **never** fall back to bare `tfsort`. |
| `ERROR` | tfsort failed / file unreadable (e.g. original is invalid HCL) | report it; file untouched |

Exit code is `0` only when every file was handled safely; `1` if any file was reverted
or errored.

## When a file is REVERTED

Do **not** work around it by running bare `tfsort` — that is exactly the content loss
this skill prevents. Instead: report the unrecoverable lines to the user, and either
sort that file by hand (moving each block with its full leading comment block) or leave
it unsorted and move on. A revert means the file's structure is something the wrapper
won't sort safely (often a heredoc or unusual layout) — surface it rather than forcing it.

## Notes

- Part of the Terraform workflow; pair with the usual branch/PR conventions when committing.
- The content-preservation guarantee is the point. If you ever change this skill, keep the
  invariant: never write a file whose non-blank line multiset differs from the original.

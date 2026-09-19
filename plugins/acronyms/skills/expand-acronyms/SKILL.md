---
name: expand-acronyms
description: This skill should be used to turn an always-on "spell out the shorthand" mode on or off, and to manage which acronyms are exempt from it. While the mode is on, every acronym, initialism, and abbreviation is expanded on first use in each reply — "CI (continuous integration)" — so the reader is never assumed to know the shorthand; code, identifiers, paths, flags, and quoted output stay verbatim. Also handles marking an acronym as already-known mid-conversation so it stops being expanded from the next turn onward. Triggers: "expand acronyms", "spell out the acronyms", "stop assuming I know the shorthand", "what do all these abbreviations mean", "turn on acronym expansion", "acronym mode off", "stop expanding acronyms", "I know what API means, skip it", "don't expand that one again", "which acronyms am I skipping", "/expand-acronyms". Distinct from eli5 (which explains one concept in depth for a reader lacking the background, on request) — this is an ambient output-formatting mode that changes how every reply is written, and expands terms rather than teaching concepts. Distinct from update-config (which owns settings.json generally) — this only wires and unwires its own UserPromptSubmit hook. NOT for defining or explaining a single acronym the user asked about (just answer), and NOT for rewriting acronyms inside source files, commit history, or command output.
version: 1.0.1
summary: Toggleable always-on mode that spells out every acronym on first use per reply, with a personal skip-list of already-known terms that can be added to mid-conversation; persists across compaction via an opt-in UserPromptSubmit hook.
tags: [craft]
---

# expand-acronyms — never assume the shorthand is known

A mode, not a task. While it is on, the reader is treated as fluent in the subject but not in its abbreviations.

## Why a hook and not just this file

A skill body loads once, when invoked. That is enough to hold the mode for a while, but it fades over a long session and is gone after compaction or `/clear` — exactly when a persistent formatting rule most needs to still be there. So the durable form of this mode is a `UserPromptSubmit` hook (`scripts/acronyms.sh inject`) that re-asserts the rule every turn and reads the skip-list fresh each time, which is also what makes a mid-session exemption take effect on the very next turn instead of the next session.

The hook is deterministic — shell, a state file, a text file. It never spawns `claude`, so the fork-bomb rule does not apply to it.

## The expansion contract

While on:

- **Expand on first use in each reply**, then use the bare form for the rest of that reply: "The CI (continuous integration) job calls the API (application programming interface). Once CI passes, the API returns 200." Per *reply*, not per session — a reader scrolling back to one message should not have to hunt upward for the expansion.
- **Parenthetical, lowercase unless the expansion is a proper noun**: `TLS (transport layer security)`, `AWS (Amazon Web Services)`.
- Applies to prose, headings, bullets, table cells, and commit messages.

Expand initialisms (`API`), acronyms proper (`RADAR`), and domain shorthand that functions the same way (`repo`, `env`, `k8s`, `PR`) — the point is that nothing goes by unexplained, not that it matches a dictionary definition of "acronym."

## What is never touched

Rewriting these breaks things or misquotes someone, which is worse than leaving a reader to ask:

- Code, identifiers, type names, and symbols — including inside prose backticks.
- File paths, URLs, command lines, flags, environment variable names.
- Literal tool output, logs, error text, and anything quoted from the user or a third party.

Where the meaning genuinely matters, gloss it *outside* the literal: `--tls-verify` → "the `--tls-verify` flag (transport layer security)". Never edit inside the span.

## Do not invent expansions

A confidently wrong expansion is worse than an unexpanded acronym — the reader now believes something false and has no reason to check. So:

- Unsure what it stands for → `SLSA (expansion uncertain)` and move on, or ask.
- The letters *are* the name and the expansion is historical, disputed, or nonexistent → say that once rather than manufacture one. Some names only look like acronyms.
- Project- or company-specific shorthand appearing in the user's own repo → expand it only if the repo actually defines it somewhere; otherwise flag it as undefined, which is useful information on its own.

## The skip-list

Terms the user already knows live one-per-line in `~/.claude/skill-state/acronyms-known.txt` (`#` comments allowed) and are matched case-insensitively. They are never expanded while the mode is on.

**Marking one mid-session** is the common case and should be frictionless. When the user says any of "I know what X means", "skip X", "don't expand that again", "obviously", or reacts to a specific expansion as unwanted — append it immediately, without ceremony:

```
scripts/acronyms.sh skip API JWT
```

Then honour it for the rest of the current reply as well; the hook picks it up from the next turn. Confirm in a few words at most — a mode correction is not an occasion for a summary.

Prefer over-adding to arguing. If the user pushes back on an expansion, the skip-list is the answer, not a justification of why the expansion was helpful.

## Control surface

All state lives in `~/.claude/skill-state/` — `acronyms.state` (the mode) and `acronyms-known.txt` (the skip-list). Machine-local and boundary-free; nothing about the mode belongs in a shared repo. That directory is the right home because `machine-config` captures `skill-state/` wholesale while loose files beside `settings.json` are not — [[lesson-restored-hook-without-its-state]]. Files left at the old top-level paths are moved on the next invocation.

| Command | Effect |
| --- | --- |
| `scripts/acronyms.sh on` \| `off` | Set the mode. Missing state file means off. |
| `scripts/acronyms.sh status` | Current mode, skip-list size, whether the hook is wired. |
| `scripts/acronyms.sh skip <A> [B…]` | Add to the skip-list (idempotent). |
| `scripts/acronyms.sh unskip <A> [B…]` | Remove — start expanding it again. |
| `scripts/acronyms.sh list` | Print the skip-list. |
| `scripts/acronyms.sh wire` \| `unwire` | Add/remove the `UserPromptSubmit` hook in `~/.claude/settings.json` (backs up first, merges, idempotent). |
| `scripts/acronyms.sh inject` | The hook itself. Prints the directive when on, nothing when off, always exits 0. |
| `scripts/acronyms.sh selfcheck` | Reports whether the mode actually works; exits non-zero when degraded. Run by `machine-config`'s post-restore `verify.sh`. |

`selfcheck` exists for one case that inspection cannot catch: **the hook wired with no mode file behind it**, which is what a restore used to produce. Everything looks right — the hook is present, the script runs, the exit code is 0 — and every prompt silently expands nothing. `status` answers "what is configured"; `selfcheck` answers "would this do anything".

Turning the mode on does **not** wire the hook — that edits the user's settings, so ask first and run `wire` only on a clear yes. Unwired, the mode still works for the session from this skill body alone; wired, it survives compaction and `/clear`.

Both `on`/`off` and the skip-list take effect on the next turn once wired, so there is never a need to restart a session to change the mode.

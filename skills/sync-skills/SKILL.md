---
name: sync-skills
description: This skill should be used to bring THIS machine's installed skills current — pull the skills repo and relink to the machine's chosen tag subset — and, on FIRST run, prompt for which skill set this machine should install (remembered thereafter). Routine catching up is now automatic at session start, so reach for this to pick or RE-SCOPE the tag subset, or to resolve what auto-sync deliberately refuses to touch: a dirty working tree, a diverged branch, or a failed fast-forward. Run it when the banner says "skills: first run", "local changes", "behind/ahead", or "sync skipped". Triggers: "/sync-skills", "sync my skills", "update my skills", "pick my skills", "re-scope my skills", "which skills are installed", "why didn't my skills sync". Distinct from the engine's `update` skill (which converges the wiki-engine itself) and from `checkpoint` (which curates vault content) — this converges only the pleejr/skills install and its tag subset.
version: 2.1.2
summary: Converge this machine's installed skills — pull + relink to its tag subset, pick the set on first run, and resolve what session-start auto-sync refuses (dirty tree, divergence). The skills-side counterpart to the engine's `update`.
tags: [craft]
---

# sync-skills — bring this machine's installed skills current

Converge the **skills** install: pull the skills repo and relink to the subset this machine wants. Deterministic (git + the repo's own idempotent scripts); **never** spawn `claude`, never touch secrets. This handles the *skills* side only — the wiki-engine itself is converged by the engine's `update` skill (they pair up; the session banner may nudge toward either).

## 1. Resolve this machine's skill choice (first-run picker)

The chosen subset is remembered in **`~/.claude/skill-tags`** (one line: a comma list like `craft` or `craft,infra,ops`, or empty = all):

- If `~/.claude/skill-tags` exists, read it — that's the choice; **don't re-prompt** (re-nagging every session is the anti-goal).
- Else if a machine manifest declares `SKILL_TAGS=` (see the `machine-config` skill), seed from it and write `~/.claude/skill-tags` to match.
- Else this is **first run** — ask the user (options: `craft` — general only, suits a personal/boundary-light machine; `craft,infra,ops` — everything, suits a work box; or a custom list). Write the answer to `~/.claude/skill-tags`.

## 2. Converge the skills

Locate the skills-repo clone from an existing link (robust across machines/dir-names): `repo=$(cd "$(dirname "$(readlink ~/.claude/skills/sync-skills)")/.." && pwd)` — this skill is installed whenever its body runs, so its own link is the one that cannot be missing. Then, with `$TAGS` from step 1:

```sh
if [ -n "$TAGS" ]; then "$repo"/bin/sync.sh --tags "$TAGS"; else "$repo"/bin/sync.sh; fi
```

Spell the branch out rather than using `${TAGS:+--tags "$TAGS"}`: **zsh does not word-split an unquoted parameter expansion**, so that idiom passes `--tags craft` as a *single* argument and the sync fails on an unknown arg.

`sync.sh` forwards `--tags` to `link.sh`, so the machine stays scoped to its subset on every sync (not just first link). It now validates the arguments **before** pulling, so a bad invocation can no longer advance the repo and then fail on the link step — a half-applied sync that exits 1 while looking like it did nothing. Report what linked/pruned.

## 3. How this relates to session-start auto-sync

Routine catching up no longer needs this skill. The `session-check.sh` drop-in (installed by `link.sh` into `~/.claude/session-checks.d/`) fast-forwards the repo and relinks on **every session start**, so an up-to-date machine is the default rather than something the user is periodically nagged into.

What auto-sync deliberately will **not** do — because a hook has no human watching it — is where this skill earns its place:

| Banner | Meaning | What to do here |
|---|---|---|
| `skills: first run` | no `~/.claude/skill-tags` | run step 1's picker |
| `skills: local changes` | uncommitted work in the repo | offer to commit + PR it, or let the user settle it, then sync |
| `skills: N behind / M ahead` | diverged from origin | push or rebase the local commits — auto-sync only fast-forwards |
| `skills: on branch X` | not on the default branch | finish or park that branch |
| `skills: fast-forward failed` | ff refused | run `bin/sync.sh` manually and read the error |

Auto-sync stays silent when the repo is current or the machine is offline, so a quiet banner means nothing needs doing.

## 4. Report + hand off

Summarize what linked/pruned. Then point onward: the **engine** side (pin, wiring) is the `update` skill's job; session *content* is `checkpoint`'s. `sync-skills` keeps your installed skills current — nothing more.

## Rules

- **Deterministic only** — git + the repo's idempotent scripts (`sync.sh`, `link.sh`). Never spawn `claude`. **This skill** stays in-session / on demand; what *is* wired to a hook is the deterministic `session-check.sh` drop-in, which is git-only and cannot recurse into `claude` — exactly the case the engine's rule permits ("deterministic hooks need no guard"). The rule bars a hook that spawns `claude`, not a hook that runs `git`.
- **No secrets; boundary-aware** — touches only the skills install, never project data.
- **Don't re-prompt for skills** once `~/.claude/skill-tags` is set; only re-surface a choice if genuinely new skill *domains* appear.
- **Skills-only** — the engine (pin/wiring/vault) is converged by the engine's `update` skill, not here.

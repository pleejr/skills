---
name: skill-author
description: This skill should be used when authoring or maintaining a Claude Code skill in this repo — writing a new SKILL.md, refining a skill's description so it triggers reliably, or diagnosing why a skill under- or over-triggers. It encodes this repo's house conventions (frontmatter shape, the explicit `Triggers:` line, the disambiguation clause) and treats the description as the routing surface that determines contextual invocation. Delegates the rigorous eval / benchmark / description-optimization loop to Anthropic's bundled `skill-creator`. Triggers: "write a skill", "create a skill", "add a new skill", "turn this into a skill", "improve this skill's description", "why isn't my skill triggering", "this skill fires when it shouldn't", "make this skill trigger reliably", "review this SKILL.md". Distinct from `scrutinize` (general artifact critique) — this is specifically about skill construction and trigger design.
version: 1.1.0
summary: House-style guide for authoring skills in this repo — the description-as-routing-surface formula, frontmatter/body conventions, an overlap check against the existing catalog, and trigger-debugging. Delegates the eval/optimization loop to Anthropic's skill-creator.
---

# skill-author — write skills that trigger by judgement

A thin **house-style layer** for building skills in this repo. It does not reproduce Anthropic's skill machinery — for the rigorous draft → test → benchmark → optimize loop, **delegate to the bundled `skill-creator`** and measure with `scripts/trigger_eval.py` (§7). This skill's job is the part that machinery assumes you already got right: designing the **description** so the skill fires on the right prompts and stays quiet on the wrong ones, and keeping every skill consistent with the repo's conventions.

## 1. Why the description is the whole game

Skills load by **progressive disclosure**: at session start only each skill's `name` + `description` is in context; the `SKILL.md` body loads *only after* the skill is invoked. So when Claude judges "is this skill relevant here?", it is matching the user's prompt against the **description alone** — it has never seen the body.

Consequence: the description is not documentation *about* the skill, it is the skill's **routing surface**. A perfect body behind a vague description is a skill that never fires. Spend the effort here.

Two known failure modes to design against:
- **Under-triggering** (the common one) — Claude has a tendency not to invoke a skill even when it would help, especially for tasks it thinks it can do unaided. Combat it by making descriptions a little **pushy** and listing concrete trigger phrases (below).
- **Over-triggering** — a description that overlaps a neighbour poaches its prompts. Combat it with explicit **negatives** and a **disambiguation clause** (§2, §4).

Also true, and worth knowing: Claude only consults skills for tasks it *couldn't* trivially handle itself. A one-step "read this file" won't trigger a skill no matter how good the description — so write descriptions (and test prompts) around substantive, multi-step uses.

## 2. The description formula

Write the description in **third person** ("This skill should be used when…"), and make it do five things:

1. **What it does** — one clause on the capability.
2. **When to use it** — the contexts/intents that should invoke it. This is what actually enables the match; do not omit it.
3. **Trigger phrases** — a `Triggers:` line with verbatim things a user would actually say, in mixed register (formal and casual). These are the highest-signal part.
4. **Disambiguation** — a "Distinct from X…" clause naming the neighbour skill(s) it must not poach, and how it differs.
5. **Negatives** — the near-miss cases where it should *not* fire (a "NOT for…" clause). Telling Claude when to stay quiet is as valuable as when to fire.

House format (matches every skill in this repo):

```yaml
description: This skill should be used when <what> — <when/contexts>. <one-line what-it-produces>. Triggers: "<phrase>", "<phrase>", "<phrase>". Distinct from <neighbour> (<their job>) — <how this differs>. [NOT for <near-miss> — use <other> instead.]
```

The router sees roughly the first **1536 characters** of a description; keep what/when/`Triggers:`/`Distinct from`/`NOT for` inside **1400** (`wc -c` on the description line, folded lines joined). What falls off the end is always the disambiguation tail — the part the formula exists for.

Model examples already in this repo: `scrutinize` (rich `Triggers:` + a "distinct from a line-level diff bug-hunt or security-only pass" clause) and `read-the-plan-before-the-apply` (the full formula with mutual `Distinct from` clauses). Read those before writing a new one.

## 3. Frontmatter conventions (this repo)

```yaml
---
name: <kebab-case>          # matches the plugins/<plugin>/skills/<name>/ directory exactly
description: <the §2 formula>
version: 1.0.0              # semver; bump on meaningful change
summary: <one sentence>     # feeds the auto-generated README table — keep it tight and factual
---
```

- `summary` is consumed by `bin/gen-readme-skills.sh` between the README sentinels — regenerate after any add/rename (§6).
- Some older skills use `status: active` + `updated: <date>` instead of `version:`; either is accepted, but prefer `version:` for new skills.
- No `tags:`. The plugin a skill lives in is its grouping, for install and for the README; a machine that wants fewer skills enables fewer plugins.

## 4. Body conventions

- **Voice:** imperative / infinitive ("Establish the contract first"), not second person ("You should…"). Consistent for AI consumption.
- **Lean:** target ~1,500–2,000 words, hard ceiling ~500 lines. If it grows past that, push detail into `references/*.md` and point to it — that's progressive disclosure at the body level (bundled resources load only when needed).
- **Explain the why, don't shout.** Prefer "do X because Y breaks otherwise" over musty all-caps `ALWAYS`/`NEVER`. Today's model has good theory of mind; a reason generalizes, a rigid rule overfits. Reserve emphasis for genuine footguns.
- **Boundary-aware:** these skills are boundary-agnostic and may run inside a work vault. Never bake in secrets; environment-specific values (org ids, sites) resolve from `skill-config.env`, not the SKILL.md (§6). Never write secrets into any output the skill produces.
- **Bundled resources** when they'd pay off: `scripts/` for deterministic work rewritten every run, `references/` for docs loaded on demand, `assets/` for output templates. Reference them explicitly from the body or Claude won't know they exist.

## 5. Overlap check (do this before adding a skill)

A new skill that shadows an existing description degrades *both*. Before committing:

1. List current descriptions: `grep -rh "^description:" plugins/*/skills/*/SKILL.md`.
2. Ask: does any existing skill already claim these trigger phrases? If so, either fold the capability into that skill, or add a mutual disambiguation clause to both.
3. Confirm the new skill's negatives explicitly cede the near-miss prompts to whoever owns them.

## 6. Repo integration

- Skills live at `plugins/<plugin>/skills/<name>/SKILL.md`, one plugin per family, each listed in `.claude-plugin/marketplace.json`. A skill that ships a hook gets a plugin of its own, so enabling a family never adds a hook silently. Every skill in this repo ships in a plugin, including hook-free ones: a single symlinked holdout would keep a second delivery mechanism alive for the whole repo.
- A hook goes in the plugin's `hooks/hooks.json` as `${CLAUDE_PLUGIN_ROOT}/skills/<name>/scripts/<file>`, never in `settings.json`. A script meant to be run by hand goes on the plugin's `bin/` as a symlink, which puts it on the Bash tool's `PATH` as a bare command.
- **A script reachable through a symlink resolves its OWN FILE through the link before deriving any path from it.** `cd -P "$(dirname "${BASH_SOURCE[0]}")"` resolves only the directory, so invoked as `bin/<cmd>` it lands in `bin/` and every sibling path is wrong. Loop `readlink` on the file first (see `machine-config/scripts/session-check.sh`).
- After adding/renaming/removing a skill, regenerate the README table: `bin/gen-readme-skills.sh` (writes between the `<!-- skills:start -->` / `:end -->` sentinels from each `summary`).
- For live development, add the marketplace from your clone (`claude plugin marketplace add <skills clone>`): a directory marketplace runs its plugins in place, so an edit is live in the next session.
- Reference bundled scripts as `scripts/<file>` relative to the skill directory. When a body must give an absolute path, prefer the plugin's bare `bin/` command, or `${CLAUDE_SKILL_DIR}/scripts/<file>`; never spell `~/.claude/skills/<name>`: a plugin install has no such directory, and the checkout path differs per machine.
- Environment-specific values go in `~/.claude/skill-config.env` (`KEY=value`), resolved first-found-wins (flag → env → config). Secrets (tokens, webhooks) live in their own chmod-600 files, never in this repo or in `skill-config.env`.

## 7. Delegate the eval loop to skill-creator — measure with `scripts/trigger_eval.py`

For the draft → test → benchmark → optimize loop, use Anthropic's bundled `skill-creator` (`~/.claude/plugins/marketplaces/claude-plugins-official/plugins/skill-creator/skills/skill-creator/SKILL.md`): its `improve_description.py` diagnoses eval failures well and `run_loop.py` owns the train/held-out description search. Do not reimplement either here.

Its measurement half was shown broken on Claude Code 2.1.231 — `run_eval.py` renames the skill under test to `<name>-skill-<uuid>` (the NAME carries routing signal) and registers it as a slash command — so it reported a working description as non-triggering. Status of each defect: `references/trigger-eval.md`. Re-measure with `scripts/trigger_eval.py` before trusting either harness on a new Claude Code version: it measures the skill as actually installed, under its real name, and refuses to report (`instrument: FAILURE`) if its positive control does not trigger.

```bash
python3 scripts/trigger_eval.py --skill <name> --eval-set references/trigger-eval-sets/<name>.json --model sonnet --runs 2 --workers 6
python3 scripts/trigger_eval.py --skill <name> --mid-task-set references/trigger-eval-sets/<name>-midtask.json --runs 1 --workers 4 --timeout 240
```

- **Budget first.** Every query spawns a `claude -p` that bills to the account — a 16-query set at 2 runs is ~34 spawns, a two-candidate comparison with holdout several hundred. Say the cost before starting.
- **Also run `--mid-task-set`.** Prompt-mode items are phrased in the operator's voice and cannot reach the failure that recurs: the model takes a measurement mid-task and states the verdict with no prompt in between. A skill can score 14/14 in prompt mode and never have fired in practice. One mid-task item must carry `detector_control: true` and name the skill outright; `controlled` (a further probe, no Skill call) is a pass. Fixture authoring and result reading: `references/trigger-eval.md`.
- Eval sets live in `references/trigger-eval-sets/`; every paid-for run is kept verbatim in `references/trigger-eval-results/` — read the last score there before re-running.

## 8. Debugging triggering (the high-value case)

When a skill fired when it shouldn't have, or didn't when it should, the fix is almost always in the **description**, not the body:

- **Under-fired:** the prompt's real phrasing isn't represented. Add it to `Triggers:`, and push the description a touch harder on the intent.
- **Over-fired:** it's poaching a neighbour. Add/sharpen the "Distinct from…" clause and a "NOT for…" negative.
- **Genuinely ambiguous:** two skills legitimately match — give both a mutual disambiguation clause so the boundary is stated from each side.
- Then **verify with `scripts/trigger_eval.py`** (§7) rather than eyeballing — add the exact prompt that misbehaved to the eval set.

## 9. Checklist

- [ ] `name` matches the directory, kebab-case.
- [ ] Description: third person, what + when + `Triggers:` line + disambiguation + negatives.
- [ ] Description ≤1400 chars (`wc -c` on the line, folded lines joined).
- [ ] Overlap check run against existing descriptions (§5).
- [ ] Body: imperative voice, lean, "why" over musty MUSTs, no secrets.
- [ ] `summary` set; `bin/gen-readme-skills.sh` re-run.
- [ ] Bundled resources referenced from the body if present.
- [ ] Triggering verified with `scripts/trigger_eval.py` (§7).

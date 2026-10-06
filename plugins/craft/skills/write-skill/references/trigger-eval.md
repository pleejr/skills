# Trigger evaluation — why `trigger_eval.py` exists, and how to read a mid-task run

Moved out of `SKILL.md` §7 on 2026-09-01. The verdict below was **measured 2026-08-13 on Claude Code 2.1.231**; the bundled `skill-creator`'s `run_eval.py` now also detects a `Read` of the command file (so count 1 is partly stale) — **not re-measured** since. Re-measure before trusting either harness on a new Claude Code version.

## skill-creator's measurement was broken on 2.1.231 — use `scripts/trigger_eval.py`

**`run_eval.py` reports a working description as non-triggering**, measured 2026-08-13, on two independent counts that both fail in the same direction:

1. It registers the skill under test as a **slash command** in `<project>/.claude/commands/`, then detects triggering by looking for a **`Skill` tool call** naming it. Those are different surfaces on this version, so the name it waits for can never appear.
2. It renames the skill to `<name>-skill-<uuid>`. Controlled comparison, same description and body, user-level install: under `rtp-probe-abc123` the model invoked nothing at all; under `read-the-plan-before-the-apply` it fired the `Skill` tool as its first action. **The skill NAME carries routing signal**, so randomising it degrades the very thing being measured.

Either defect alone turns a good description into a 0% trigger rate, and the improvement loop then rewrites a description that already works. Do not run `run_loop.py` and act on its numbers.

`scripts/trigger_eval.py` measures the skill as actually installed — a plugin skill as `--skill <plugin>:<name>`, read from the directory the session loads it from (the source tree for a directory marketplace, else the installed copy), or a user-level `~/.claude/skills/<name>/` by its bare name — real name, detection on a `Skill` tool call naming it — and swaps a real directory in under the **same name** to score a candidate description, so only the description varies. It **refuses to report results at all** if its positive control does not trigger, printing `instrument: FAILURE` instead, because a harness that cannot detect a known-good case cannot score an unknown one.

```bash
python3 scripts/trigger_eval.py --skill <plugin>:<name> --eval-set references/trigger-eval-sets/<name>.json \
        --model sonnet --runs 2 --workers 6
```

Eval sets for the skills measured so far are in `references/trigger-eval-sets/`, and the raw output of runs that were actually paid for is kept verbatim in `references/trigger-eval-results/` — check there before re-running, since the question at the next description edit is always what it scored last time, and a remembered number is not a measurement. **Budget before running: every query spawns a `claude -p` subprocess that bills to the account** — a 16-query set at 2 runs is ~34 spawns, and a two-candidate comparison with a holdout is several hundred. Say the cost out loud before starting, not after.

## A query-shaped eval measures only half of what matters — also run `--mid-task-set`

Every item in an ordinary eval set is phrased in the **operator's** voice: *"the query came back empty, is that real"*. That measures whether a description matches somebody else's stated doubt. It cannot reach the failure that actually recurs — the model takes a measurement itself, mid-task, and states the verdict as a finding, with no prompt in between for any description to match.

The consequence is worth stating plainly, because it looks like success: **a skill can score 14/14 in prompt mode and have never once fired in practice**, and prompt mode will never say so. It scores over the rare population.

```bash
python3 scripts/trigger_eval.py --skill <name> \
        --mid-task-set references/trigger-eval-sets/<name>-midtask.json \
        --runs 1 --workers 4 --timeout 240
```

A mid-task item is a **task plus a fixture** rigged so the natural first probe returns nothing, and what is scored is what happens after that empty result. Four outcomes: `routed` (a Skill call after it), `controlled` (no Skill call but a further probe actually run), `bare` (the absence answered with neither), and `no-empty-result` (nothing came back empty, so nothing was measured).

Three things about it are load-bearing:

- **One item must carry `detector_control: true` and name the skill outright in its task.** The expected finding in this mode is "never fires", which is indistinguishable from "the harness cannot see it fire". The detector control tests the *detector*, not the description, and the run prints nothing at all if it does not come back `routed`.
- **`controlled` counts as a pass, because Skill-call detection measures the wrong thing here.** Measured while building this: given an empty grep, the model ran two further probes and answered *"the empty grep result is a real negative, not a broken search"* — the exact behaviour the skill exists to produce, with no Skill call anywhere. A Skill-only detector scores that a non-trigger and reports a working description as broken.
- **Positive and negative items are scored on different criteria, deliberately.** A negative is scored purely on whether the skill was invoked, never on tool count — the first version counted any second tool call as an audit, so ordinary multi-step work (`['Write','Bash']`) scored as though it had verified something, and both negative controls failed for a reason that had nothing to do with the description.

**Authoring the fixture is where this goes wrong, and it fails loudly rather than quietly.** A fixture must make the empty-returning probe the *rational* move: with two or three small files the model reads them all and genuinely answers, so no probe ever comes back empty and the item measures nothing. Those runs are reported `no-empty-result` and left **unscorable** rather than counted as non-triggers, so a fixture bug is never charged to the description. Measured shape that works: ~27 files of volume, with the searched literal genuinely absent and the real answer reachable only by meaning — first attempt scored 3 of 4 positives unscorable, and the same items scored 4 of 4 once volume was added.

**Read a mid-task result for what else was in context.** These spawns inherit `~/.claude/CLAUDE.md`, so an always-on rule about the same behaviour will lift the numbers and the harness cannot separate that from the description's own effect. If a baseline matters, establish it before shipping such a rule — afterwards there is no clean one to get.

---
name: herdr-name
description: Name the current Herdr space after the work in progress — a 1-2 word domain label on the space itself, plus a 4-5 word topic line beneath it — so the sidebar says what each session is actually doing. On demand only, never per-turn: the naming comes from session context already in hand, so it costs one command and no summarizer. Also clears a name back to the space's original label. Triggers "/herdr-name", "name this space", "rename the space", "update the space name", "set the space topic", "what is this space called", "clear the space name", "restore the space name". Distinct from the bundled `herdr` skill (which controls panes, tabs, and agents to do work) — this only labels the current space for display. NOT for renaming tabs or panes, and NOT for creating or closing workspaces.
version: 1.1.2
summary: On-demand Herdr space naming — a 1-2 word domain label plus a 4-5 word topic, applied from session context with no summarizer call.
tags: [craft]
---

# herdr-name

Herdr's sidebar lists spaces by label. A space called `General` tells you nothing about what the session inside it is doing. This skill names the space after the work in progress, and a later session clears it again.

Two strings, two surfaces:

- **Label** — 1–2 words naming the *domain* of work. Replaces the space's own name, shown in the sidebar. Max 32 characters.
- **Topic** — 4–5 words expanding the label into the specific work. Shown as a second sidebar row via display-only workspace metadata. Max 32 characters.

**Both fields cut off at 32 characters.** Count the characters before you apply a name. Write a shorter word rather than a long one that does not fit. The script fits an over-long string on whole word boundaries, and reports the trim on stderr, but a name that arrives complete is always better than one the script had to cut.

```
SPACES
  ● Herdr Naming
      Design on-demand space rename
```

## Why on demand, and not per turn

A per-turn summarizer costs a model call per turn for a label that changes once an hour — [[lesson-per-turn-model-call-uneconomic]]. **You already hold the session context**: read the work from the conversation in front of you and write both strings directly. No transcript read, no second model, no per-turn hook. The cost is one `Bash` call.

## Applying a name

```bash
S=~/.claude/skills/herdr-name/scripts/herdr-name.sh

$S set "Herdr Naming" "Design on-demand space rename"
$S show      # current label, topic, and the saved original
$S reset     # restore the original label, clear the topic
```

The script holds no judgement — it applies what you give it, fits each field to 32 characters on a word boundary, and remembers the space's original label the first time it renames so `reset` can put it back.

## Procedure

1. Confirm this session is inside Herdr. Run `test "${HERDR_ENV:-}" = 1`. If it fails, say you are not running inside Herdr and stop.
2. Read the domain of work from the conversation already in context. Do not read the transcript file and do not spawn a subagent — both are wasted work.
3. Check whether the space is shared. Run:

   ```bash
   herdr pane list --workspace "$HERDR_WORKSPACE_ID"
   ```

   For every *other* pane whose `agent` is `claude`, read its `terminal_title_stripped`. Those are sibling sessions in the same space; fold their work into the label so the name covers the whole space rather than just this pane.
4. Compose the two strings against the rules below.
5. Count the characters in each string. If either exceeds 32, rewrite it shorter. Do not hand the script a string that it must cut.
6. Show both to the user before applying. One line, no preamble.
7. Apply with `$S set "<LABEL>" "<TOPIC>"`.

## Writing the label

- **1–2 words, title case, max 32 characters.** It has to fit a sidebar column.
- Name the **domain**, not the current action. `Herdr Naming`, not `Editing Script`. The label should survive several turns of work inside the same domain.
- Prefer the concrete subject over the activity: `Billing Auth` beats `Terraform Work`; `Payments Triage` beats `Debugging`.
- No trailing punctuation, no leading dashes.

## Writing the topic

- **4–5 words, max 32 characters** expanding the label into the specific work in progress. 32 characters is tight for 5 words — pick short words, and drop to 4 words when they are long.
- It must add information the label does not already carry. `Herdr Naming` / `Herdr naming work` is a wasted line; `Herdr Naming` / `Design on-demand space rename` is not.
- Sentence case, no trailing period.

## Clearing a name

`reset` restores the label saved when the space was first named, and clears the topic. It refuses in two situations, both deliberate:

- **The space holds more than one `claude` pane.** A sibling session is live here, and its name stays. The command reports the pane count and changes nothing.
- **No original label was saved.** The space was never named by this mechanism, so there is nothing to restore to. Guessing a label would be worse than leaving the one the user chose.

A `SessionStart` hook runs `herdr-name.sh session-start`, which resets automatically when a genuinely new session begins. The hook reads the payload's `source` field and acts only on `startup` or `clear` — a `resume` or a `compact` continues work already in progress and keeps its name. You do not need to reset by hand at the end of a session.

**Installed as the `herdr` plugin, the hook ships with it** (`hooks/hooks.json`) and needs no wiring; the script is also on the Bash tool's `PATH` as `herdr-name`. The rest of this section applies only to a symlink install.

**The hook is not automatic under a symlink install — wire it once per machine.** Nothing in this skill installs it, and without it a name outlives the session that set it. Add this to the `SessionStart` array in `~/.claude/settings.json`, with the script's physical path (`readlink -f ~/.claude/skills/herdr-name/scripts/herdr-name.sh`) — the matcher is `*` because the script itself decides on the payload's `source`:

```json
{
  "matcher": "*",
  "hooks": [
    {
      "type": "command",
      "command": "<physical path>/skills/herdr-name/scripts/herdr-name.sh session-start",
      "timeout": 10
    }
  ]
}
```

Check it with `jq -e '.hooks.SessionStart[].hooks[] | select(.command | test("herdr-name.sh session-start"))' ~/.claude/settings.json`. The script is deterministic and never spawns `claude`, so it is safe as a lifecycle hook.

## What this skill does not do

- **It does not rename tabs or panes.** Only the space label and its topic token.
- **It does not create, focus, or close workspaces.** Use the bundled `herdr` skill for layout and agent control.
- **It never sets a name unprompted.** A name is applied when asked for, and cleared when a new session starts.

## Notes on the surfaces

The label is a durable `herdr workspace rename`; the topic is `herdr workspace report-metadata`, display-only with a 24-hour TTL. Rendering the topic requires its own row in `~/.config/herdr/config.toml`, applied with `herdr server reload-config`:

```toml
[ui.sidebar.spaces]
rows = [["state_icon", "workspace"], ["$topic"], ["branch", "git_status"]]
```

Without that row `set` reports success and `show` reads the topic back while the sidebar still draws one line — the quiet failure to look for. Surface details: [[herdr-space-naming]].

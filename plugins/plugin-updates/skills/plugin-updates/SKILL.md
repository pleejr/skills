---
name: plugin-updates
description: This skill should be used to report which installed Claude Code plugins are behind their marketplace's latest release and to update them on the user's say-so — acting on the session-start "plugins: N outdated" banner, or checking on demand. Lists each outdated plugin with installed → latest, runs the update commands the check printed only after the user agrees, then tells the user to run /reload-plugins or start a new session so the updates load. Covers every marketplace — GitHub, git, and local directory clones, including a clone behind its own upstream. Triggers: "are my plugins up to date", "check for plugin updates", "which plugins are outdated", "update my plugins", "update them", "the banner says plugins are outdated", "refresh the plugin check", "/plugin-updates". Distinct from `/plugin` (Claude Code's own install and marketplace UI) — this finds what is behind across all of them and names the commands. Distinct from wiki-engine's `update` skill, which records the engine release in a vault; that step still follows an engine update. NOT for installing a new plugin, adding a marketplace, or authoring one.
version: 1.0.0
summary: Session-start report of every installed plugin behind its marketplace's latest release — any marketplace, rate-limited lookup, self-clearing — with an offer to update and a reload instruction; never runs claude from the hook.
---

# plugin-updates — know which plugins are behind, and update them on a yes

Claude Code's marketplace auto-update is off by default for third-party marketplaces, and it
never reaches a **directory** marketplace, which installs from a local clone that nothing pulls.
So a machine can sit releases behind with no sign of it. This plugin's SessionStart hook
compares every installed plugin with its marketplace's latest release and says what it found —
including when everything is current, so a silent banner never means the check did not run.

## What the hook reports

- `plugins: N current (looked up 2h ago)` — nothing to do.
- `plugins: K outdated, N current` then one line per plugin: `craft@pleejr 88f94fdd544e → c82e4c5b…`
  or `wiki-engine@wiki-engine 2.4.1 → 2.4.2`.
- `the <mkt> marketplace clone is behind origin/main` — a directory marketplace whose clone
  needs a `git pull` before any update can see the new release.
- `not checked: <mkt> (lookup failed)` — the lookup failed and nothing was cached; this is a gap,
  never "current".

A plugin with a version (its `plugin.json`, the catalog entry, or a release tag as the entry's
`ref`) is compared by version. An unversioned plugin is installed as a marketplace commit, and is
outdated only when **its own directory** changed since that commit — a commit elsewhere in the
marketplace changes nothing it runs.

## When the banner lists outdated plugins

1. Tell the user which plugins are behind, installed → latest, in one short list.
2. Ask whether to update them now. Nothing is run before the user says yes.
3. On yes, run the commands from the hook's ACTION block, **in order** — a directory
   marketplace's `git -C <clone> pull --ff-only` must come before its `claude plugin update`.
   Take the printed commands, not remembered ones.
4. Re-run the check to confirm it is clear (below), and report what it says.
5. Tell the user to run `/reload-plugins`, or start a new session, so this session loads the
   updated plugins. A running session keeps the release it started with until then.
6. If `wiki-engine` was among them, its vault record is a separate step: offer wiki-engine's
   `update` skill.

## Checking on demand

```bash
S="${CLAUDE_PLUGIN_ROOT:-<skills clone>/plugins/plugin-updates}/skills/plugin-updates/scripts"
python3 "$S/check.py"              # the report, answered from the cache when it is fresh
python3 "$S/check.py" --refresh    # look every marketplace up now
```

## How it stays cheap and honest

- **Two rails.** The network lookup (a `git fetch` into a private mirror under
  `${CLAUDE_PLUGIN_DATA}`, or `git ls-remote` for a directory clone's upstream) runs at most once
  per `PLUGIN_UPDATES_INTERVAL` (default 86400s) per marketplace, within a 20-second budget. The
  comparison runs every session, so an update clears the report at once with no network.
- **A plugin updated after the last lookup forces a new one.** The lookup then predates at least
  one release, so a newer one may exist; waiting out the interval would hide it for a day.
- **No credentials, no prompts.** Credential helpers are off for the lookup, so a private
  repository fails as "not checked" rather than opening a keychain prompt at session start.
- **Never runs `claude`.** The hook is git and file reads only; the update commands are run by
  the assistant after the user agrees.
- `PLUGIN_UPDATES_CHECK=0` turns it off — silent, no lookup.

Tests: `scripts/test-check.sh` (local fixture marketplaces; no network).

---
name: restore
description: This skill should be used to rebuild a machine's Claude Code configuration from a snapshot — a lost or replaced laptop, a fresh machine, a rebuilt one — and to read a machine back after any converge (a plugin update, a marketplace add, a relink, an engine adoption) whose tools report success over what they cannot see. Runs restore.sh (infers the source snapshot, refuses when several could apply), rewrites local marketplaces to their remotes, prints the manual checklist a script cannot do (SSH keys, gh auth, /login, MCP re-auth) and the clone commands, re-wires autosave, and ends by asking each wired component to report its own state with verify.sh. Triggers: "I lost my laptop", "set up my new machine", "restore my Claude Code setup", "rebuild this machine's config", "cold start on a replacement", "did the restore actually work", "verify my config after the plugin update", "every skill loads twice after the update". Distinct from `snapshot` (saves and shares config FROM this machine) and from the plugin marketplace (which installs the skills themselves). NOT a dotfiles manager and NOT for restoring a different boundary's snapshot onto this machine.
version: 1.0.0
summary: Rebuild a machine's Claude Code config from its snapshot — infer the source, rewrite marketplaces to remotes, print what only a human can do, then verify each wired component by asking it; also reads any converge back.
---

# restore — rebuild the machine, then ask it whether it works

The other half of `snapshot`: the scripts live there, so this skill names them from its own
directory — `S="${CLAUDE_SKILL_DIR}/../snapshot/scripts"`.

```sh
"$S/restore.sh"                  # rebuild a machine — infers the source snapshot
"$S/restore.sh" --from <host>    # ...unless several exist, then name one
"$S/verify.sh" [--quiet]         # does the restored config actually WORK?
```

`restore.sh` with no arguments does the right thing in the disaster case: if this hostname
has no snapshot and exactly **one** exists, it uses it and says so. With several it refuses
and lists them — silently picking one could restore the wrong machine's config.

## Rules that matter

- **Restore stops at what a script cannot do** — SSH keys, `gh auth`, `/login`, MCP re-auth,
  secret files — and prints them as a checklist. A restore that silently skips those looks
  complete and isn't.
- **Marketplaces come back remote.** A `directory` marketplace runs plugins out of a working
  tree no other machine sees. `restore.sh` rewrites each one whose checkout (or `repos.txt`
  entry) has a remote to a `github`/`git` source with `autoUpdate: true`, keeping the name so
  every install survives; the session-start check flags any that remain. Develop with
  `claude --plugin-dir` instead, or set `MC_KEEP_DIRECTORY_MARKETPLACES=1` to keep one local.
- **Verify behavior, not file presence.** `restore.sh` ends by running `verify.sh`: a hook can
  be present, executable and wired, read state that never arrived, and exit 0 — only asking the
  component can see that. A degraded component is a to-do, not a failed restore, and the manual
  checklist still prints. `verify.sh` discovers what to check from `settings.json`, never from a
  list kept in the script, because a hand-maintained list rots silently.
- **Snapshots are per machine, and per boundary.** Never restore one boundary's snapshot onto
  the other's machine: it would import that boundary's paths, repo names, and memory wiring.

## Cold start on a replacement

1. Clone the skills repo (this skill) **and** the config repo. Ordering matters: the config
   repo carries the clone list for everything else.
2. `scripts/restore.sh --from <old-hostname>`
3. Work the printed manual checklist.
4. Clone the listed repos; initialise submodules where relevant.
5. `scripts/init.sh` for the new hostname, then `scripts/install.sh` — autosave takes it
   from there.
6. `scripts/verify.sh` again once the clones and links are in place. Step 2 ran it too, but
   half the machine did not exist yet — this is the run that means something.

## After any converge — read the machine back

Every step that changes this machine's wiring — `claude plugin update`, `marketplace add`, a
relink, `restore.sh`, an engine adoption — reports on what it touched, and reports **success
over whatever it cannot see**. Nothing fails; the gap shows up later as a wrong verdict. So once
the step finishes, diff the machine against the union of **every** source that should feed it,
not the one the tool knows:

- **Restart before trusting a plugin update.** `claude plugin update` installs beside the old
  release. Until the restart, the loaded skill text, a hook's stable pointer and a typed `bin/`
  path can each run a different release — a stale converge verb once re-created the skill
  symlinks the new release had removed, so every skill loaded twice.
- **After `marketplace add`, re-read the entry:** `jq '.extraKnownMarketplaces' ~/.claude/settings.json`.
  The add rewrites it and silently drops `autoUpdate`; `remote-marketplaces.sh --check` looks only
  at `directory` sources, so it will not flag this.
- **After an install or relink, diff `~/.claude/skills/` against every enabled plugin's skills**,
  across all marketplaces. A linker knows only its own marketplace and reports `already linked`
  over the collisions it cannot see.
- **An add-only, per-machine file never receives its upgrade** — a git-ignored hook installed
  once keeps its first template while every version record agrees. Compare it by checksum against
  the shipped copy, and repeat on each machine; a fix copied on one reaches no other.
- **Identify a wired entry by a marker you wrote, not by its path.** A plugin's cache path moves
  with every release, so a path match stops recognising the entry after an update, and a loose
  substring claims someone else's.
- **A slot the host allows once is not filled by enabling a plugin.** A plugin cannot provide
  `statusLine`, and a feature shipped for a slot a local script already occupies never arrives.

Restore already ends with `verify.sh`; this is the same discipline for every other converge.

## Making a skill verifiable

A skill with durable state should say whether it is working, rather than leave a restore to
infer it from files. Opt in by carrying the literal marker `# machine-config: selfcheck` in
the script `settings.json` already points at, and accepting a `selfcheck` argument that:

- takes no input and changes nothing — `verify.sh` runs it during a restore,
- prints one short line per finding, each prefixed `ok:` or `degraded:`,
- exits 0 when healthy, non-zero when degraded.

Only marker-carrying scripts are called: a hook command is arbitrary code, and probing it with an
unexpected argument could have side effects a verification pass must not cause. The retired `expand-acronyms`
was the worked example — its degraded case, a wired hook with no mode file behind it, is
indistinguishable from health by inspection.

---
name: machine-config
description: This skill should be used to make a machine's Claude Code configuration recoverable — snapshot `~/.claude` (settings, hooks, statusLine, enabled plugins, repo clone list) into a git repo the user controls, restore it onto a replacement machine, and share boundary-free preferences and output styles across machines through two stores. Use when setting up or rebuilding a machine, when a laptop is lost, when config has drifted from its snapshot, or when preferences or output styles should follow the user between machines. Wires an unattended SessionEnd autosave and a session-start style apply; scripts never spawn `claude` and refuse credential-shaped content; a restore ends by asking each wired component to report its own state. Triggers: "back up my Claude config", "snapshot my settings", "restore my Claude Code setup", "set up my new machine", "I lost my laptop", "make my config recoverable", "sync my preferences between machines", "share my output styles between my laptops", "what happens if this machine dies", "my config repo is stale", "promote this output style". Distinct from the plugin marketplace (which installs and updates the skills themselves) — this covers the `~/.claude` configuration itself. NOT a dotfiles manager (Claude Code config only) and NOT a secrets manager.
version: 1.3.0
summary: Make a machine's Claude Code config recoverable — autosaves ~/.claude to a git repo at session end, restores onto a replacement machine, and shares boundary-free preferences (output styles included) across machines from two stores, one of which crosses the work/personal boundary; secret-scanned, never spawns claude.
---

# machine-config — survive losing the machine

Losing a laptop should cost an afternoon of re-cloning, not a reconstruction of settings
nobody wrote down. This skill snapshots the Claude Code configuration that is genuinely
irreplaceable — hooks, statusLine, permissions, memory wiring, and the list of repos to
clone — into a git repo the user controls, and restores it onto a replacement.

**The machinery is here; the data lives in the user's repo.** That split is the point: one
implementation, and as many private config repos as the user has boundaries (personal, work).
The repos never need to be remotes of each other.

## Two stores, two rule sets

Sharing preferences across machines and restoring one machine are *opposite* problems, and
conflating them is the mistake to avoid. Anything that names a path, names a repo, or grants
authority must **not** be shared — and is **exactly** what must be restored.

| | `shared/` | `machines/<host>/` |
|---|---|---|
| Applied to | every machine | only that machine's replacement |
| Holds | invariant prefs (`model`, `theme`, …) + `output-styles/*.md` | full snapshot incl. `hooks`, `statusLine`, `permissions`, repo list |
| Also | a skills repo's `plugins/craft/output-styles/` reaches across boundaries — see below | — |
| Guard | fail-closed denylist (keys) + machine-local/secret scan (files) | secret scan |
| Written by | hand | `scripts/backup.sh` |

`apply.sh` **merges** `shared/` into `~/.claude/settings.json` and leaves every other key
alone, so a machine can't be broken by a pull. It refuses `hooks`/`statusLine`/`permissions`/
`autoMode`/`env` even if they appear in `shared/`, reporting each refusal — where two config
repos are kept in step by hand, a mistake on one side must not push authority onto the other.

### Output styles — files, carried by TWO stores

`settings.json` carries `outputStyle` as a **name**; only `machines/<host>/` ever carried the file it names, so a style reached one machine's replacement and no second machine. `apply.sh` installs styles from both stores into `~/.claude/output-styles/`:

| store | reaches |
|---|---|
| `<config repo>/shared/output-styles/` | every machine in **one** boundary |
| `<skills repo>/plugins/craft/output-styles/` | every machine that syncs the skills repo — **both** boundaries |

The skills store crosses the boundary, so what goes in it must carry no boundary-specific data, and the guards **cannot check that for you** — a home path and a credential have a shape; an employer, a ticket key, a colleague's name do not. The config repo is optional for this half.

- **A name carried by both stores is REFUSED, never resolved** — different reach; the refusal names both paths, delete one.
- **A style that names a home path, or carries credential-shaped content, is refused.**
- **A local style this machine did not install, or installed and then edited, is never overwritten.** `--force` takes the shared copy after backing the local one up.
- **A style byte-identical to the shared copy is adopted**, not refused — that is what a machine looks like after `restore.sh`.
- **A style dropped from EVERY store is reported, never deleted.**

Provenance: `~/.claude/.machine-config-shared-styles` (per-machine, uncommitted).

**With the `craft` plugin enabled, the skills store stands down.** Claude Code loads those styles itself as `craft:<frontmatter name>` (so `Briefing` becomes `craft:Briefing`), and a copy in `~/.claude/output-styles/` would list each one twice. `apply.sh` stops copying that store and removes a copy only when the manifest shows this machine installed it and it is unedited; an edited copy is left in place. It prints the new name but does **not** rewrite `outputStyle`, which may live in a project's settings — a stale name silently falls back to the default style, and the session-start hook says so first.

**`--promote <name>` publishes THIS machine's style into a shared store** through the same guards, printing the commit commands rather than committing. Without it the machine that produced an improvement is the one that stops receiving updates for it, because autosave snapshots only into `machines/<host>/`. Where the name already lives wins; a new name defaults to the **skills** store (`--to skills|config` overrides).

**Styles install themselves at session start (`session-apply.sh` → `apply.sh --styles-only`, writes); settings only warn (`session-check.sh` → `apply.sh --check --settings-only`).** Under the plugin both run from `scripts/session-hook.sh`. Under the legacy install they are `session-checks.d` drop-ins, and the `zz-` prefix on the apply one is load-bearing: the drop-ins run in glob order and the skills store is synced by a *different* drop-in, so an apply sorting before that sync reads the store as it was before it. A change to the ACTIVE style says `RESTART` in the banner — the session read its style file before the hook fired.

**Exit status**: `0` clean · `1` drift under `--check` · `2` usage · `3` applied what it could and **refused** at least one thing `shared/` asked for. `--check` returns the status the real run *would* — refusal first. `scripts/test-apply.sh` is the fixture gate; this repo runs no CI.

The full rationale — why two stores, why refuse rather than resolve, the adopt and orphan rules: `references/output-styles.md`.

## Workflow — two commands, then never again

```sh
scripts/init.sh ~/path/to/config-repo   # once per boundary; points this machine at it
claude plugin install machine-config@pleejr   # hooks arrive with the plugin
```

**Plugin delivery** (`plugins/machine-config/hooks/hooks.json`) wires a SessionEnd hook running `autosave.sh` and one SessionStart hook, `session-hook.sh`, which runs both session checks and reports through the hook's `systemMessage` and `additionalContext`. While the plugin is enabled, the legacy wiring stands down: the drop-ins exit silently, and `install.sh` removes its own settings hook and links instead of adding them.

**Legacy delivery**, for a machine without the plugin: `scripts/install.sh` adds a **SessionEnd hook** running `autosave.sh`: it snapshots, commits and
pushes whenever config changed, and does nothing when it didn't. It also links the optional
session-start drift check as a safety net that speaks up only if autosave has been failing, and
the session-start **style apply**, which is what makes shared output styles arrive on their own.

The rest exist for when a human is driving, and should be run **for** the user rather than
handed to them as commands to memorise:

```sh
scripts/restore.sh                  # rebuild a machine — infers the source snapshot
scripts/restore.sh --from <host>    # ...unless several exist, then name one
scripts/backup.sh [--check]         # manual snapshot / drift check
scripts/verify.sh [--quiet]         # does the restored config actually WORK?
scripts/apply.sh [--check|--force]  # merge shared prefs + install shared output styles
scripts/apply.sh --styles-only      # ...only the styles half (what the session-start hook runs)
scripts/apply.sh --settings-only    # ...only the settings half
scripts/apply.sh --promote <name>   # publish THIS machine's output style into a shared store
scripts/apply.sh --promote <name> --to skills|config   # ...naming the store explicitly
scripts/test-apply.sh               # fixture pass over apply.sh's guards (no CI here)
scripts/install.sh --remove         # unwire (legacy delivery)
```

`restore.sh` with no arguments does the right thing in the disaster case: if this hostname
has no snapshot and exactly **one** exists, it uses it and says so. With several it refuses
and lists them — silently picking one could restore the wrong machine's config.

The repo is located from `$MACHINE_CONFIG_REPO`, else `~/.claude/machine-config-repo` (a
one-line pointer `init.sh` writes). Never guess it — a wrong guess snapshots into, or
restores from, the wrong boundary's repo.

`backup.sh` reads the clone list from `$MC_REPOS_DIR` (default `~/Documents/repos`) and records
that directory in `repos.txt`'s header, so `restore.sh` prints clone commands for the layout the
old machine actually had.

## Rules that matter

- **Refuse rather than repair.** `backup.sh` exits non-zero on credential-shaped content
  (token prefixes, private-key headers, `"token": "…"`) instead of committing it — a snapshot
  that silently commits a secret is a leak wearing a green checkmark, and `autosave.sh` pushes
  with no human in the loop. Never strip the check: move the value to a chmod-600 file and
  re-run, or widen `MC_SECRET_RE`. A refusal is never silent — the session-start check reports
  that nothing is being recorded.
- **Autosave commits only this machine's snapshot** (`git add machines/<host>`), never
  `git add -A`. A half-finished `shared/` edit sitting in the same working tree is not the
  hook's to commit.
- **Config, not state — but a mode is config.** Conversation history, `projects/`, `sessions/`,
  telemetry and caches are never captured. A skill's durable *mode* — small, chosen, invisible
  when lost — belongs in `skill-state/`, captured wholesale alongside `bin/` and `hooks/`; a hook
  restored without the state it reads is a mode that is silently off. Loose files in `~/.claude`
  are reached only by the hand-maintained `MC_FILES` list, so a new one is missed by default.
- **Never spawn `claude`** — not even `claude --version` (the version is read from the
  install symlink). These scripts run from a SessionStart drop-in, where that contract is
  absolute; see the no-`claude`-in-hooks trap.
- **Restore stops at what a script cannot do** — SSH keys, `gh auth`, `/login`, MCP re-auth,
  secret files — and prints them as a checklist. A restore that silently skips those looks
  complete and isn't.
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

## Making a skill verifiable

A skill with durable state should say whether it is working, rather than leave a restore to
infer it from files. Opt in by carrying the literal marker `# machine-config: selfcheck` in
the script `settings.json` already points at, and accepting a `selfcheck` argument that:

- takes no input and changes nothing — `verify.sh` runs it during a restore,
- prints one short line per finding, each prefixed `ok:` or `degraded:`,
- exits 0 when healthy, non-zero when degraded.

Only marker-carrying scripts are called: a hook command is arbitrary code, and probing it with an
unexpected argument could have side effects a verification pass must not cause. `expand-acronyms`
is the worked example — its degraded case, a wired hook with no mode file behind it, is
indistinguishable from health by inspection.

## When advising

Check `scripts/backup.sh --check` before telling a user their setup is safe — a config repo
that hasn't been committed since March protects nothing. If they have no config repo at all,
say so plainly: the failure mode is silent until the day it isn't.

**Never write another machine's paths into a handoff — resolve them.** This skill's whole
premise is that machines differ, so a command block naming *your* checkout is untested prose on
theirs. Two clones move: the config repo, which is why `~/.claude/machine-config-repo` exists and
is never guessed; and this skills checkout itself, whose location the target machine already
records in the symlink that installed it:

```sh
MC="$(readlink ~/.claude/skills/machine-config)/scripts"   # the symlink IS the pointer
"$MC/apply.sh" --check
```

Verify a resolver by running it before you hand it over. The scripts resolve their own siblings
via `BASH_SOURCE`, so only prose gets this wrong — and a handoff naming one machine's checkout path
has failed every command on another.

**Do not predict which branch `apply.sh` will take on a machine you cannot see** — run `--check`
and read it. A machine already running a shared style hits the adopt branch (reported, exit 0),
not the install branch; exit 1 means **your config** would change, and adopting an identical file
is not drift.

**Re-check before acting on the session-start note, however old the session is.** It fires once
at startup while autosave runs at every SessionEnd, so a concurrent session can commit the
reported drift minutes later; snapshotting on a stale note is a harmless no-op that reads as the
check having been wrong.

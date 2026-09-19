# Output styles — the full rationale

Moved out of `SKILL.md` on 2026-09-01; the body keeps the rules, this keeps the why. `scripts/apply.sh`'s header carries the same reasoning next to the code that enforces it.

## The file half, carried by TWO stores

An output style is the clearest thing the shared store was meant for: hand-authored prose about
*how to write*, naming no path, no repo and no authority. It had no route anyway. `settings.json`
carries `outputStyle` as a **name**, the Markdown file lives beside it, and only `machines/<host>/`
ever carried that file — so a style reached exactly one machine's replacement and no second
machine at all. Sharing the setting without the file it points at is the same
restore-a-pointer-to-nothing failure `MC_DIRS` exists to prevent, one layer up.

Styles come from **two** stores, and `apply.sh` installs both into `~/.claude/output-styles/`:

| store | reaches |
|---|---|
| `<config repo>/shared/output-styles/` | every machine in **one** boundary |
| `<skills repo>/plugins/craft/output-styles/` | every machine that syncs the skills repo — **both** boundaries; with the `craft` plugin enabled Claude Code loads it directly as `craft:<name>` and `apply.sh` stands down for it |

The config repo is per boundary: work and personal are separate repos that are never remotes
of each other, so `shared/` structurally cannot carry a style from a work laptop to a personal
one. A skills repo already crosses that gap, because it is consumed from both setups by
contract — which is also its constraint: what goes in it must carry no boundary-specific data,
and the guards below **cannot check that for you**. A home path and a credential have a shape;
an employer, a ticket key, a colleague's name and an internal system do not. `--promote` says
so out loud on the way into that store rather than pretending to test it.

**A name carried by both stores is REFUSED, never resolved** — they have different reach, so
silently preferring either installs prose the operator believes lives somewhere else, and then
tracks updates from the wrong copy forever. The refusal names both paths; delete one.

**The config repo is optional for this half.** A second laptop may want the shared prose and
keep its own config elsewhere; dying there would withhold styles from exactly the machine the
cross-boundary store exists to reach. The settings half still requires it.

It carries **files**, not keys, so its guards are the file-shaped analogues of the denylist:

- **A style that names a home path, or carries credential-shaped content, is refused.** The
  boundary rule is "if it names a path, a repo, or grants authority, it is machine-local", and a
  Markdown file has no keys to test that on — so the test moves to its content.
- **A local style this machine did not install, or installed and then edited, is never
  overwritten.** This is irreplaceable prose, not a cache. `--force` takes the shared copy after
  backing the local one up; doing nothing keeps yours.
- **A style byte-identical to the shared copy is adopted**, not refused — that is what a machine
  looks like after `restore.sh` put the file there, and refusing it would make every later shared
  update read as an operator edit, forever.
- **A style dropped from EVERY store is reported, never deleted.** Removing a config file its
  owner can still see is not a merge — and a style still carried by the *other* store is not
  dropped at all, so the report would invite deleting a file that is still managed.

Provenance lives in `~/.claude/.machine-config-shared-styles` (per-machine, uncommitted): without
it, "differs from `shared/`" cannot tell a shared update apart from prose written here.

**`--promote <name>` is the other direction, and without it nothing is really shared.** A style
is edited where it is *used* — `~/.claude/output-styles/` — and autosave then snapshots it into
`machines/<host>/`, the restore half, which no other machine reads. `shared/` never learns; worse,
that machine's own next `apply.sh` refuses the file as an operator edit. **The machine that
produced the improvement is the one that stops receiving updates for it.** `--promote` copies the
local style into a shared store through the same guards, which run harder in this direction
because this is where a home path or a credential would *enter* the store and be handed to every
machine. It does **not** commit — committing is what publishes — and prints the commands instead.

**Which store?** Where the name already lives wins, because promoting into the store it is *not*
in is how one name ends up in two — the conflict `apply.sh` refuses on the way back in. A name in
both is refused here too. Only a genuinely new name falls through to a default, and that default
is the **skills** store, since crossing the boundary is usually what sharing a style means.
`--to skills|config` overrides.

**Styles install themselves at session start; settings only warn.** Two drop-ins, two blast
radii:

- `zz-machine-config-apply.sh` → `session-apply.sh` runs `apply.sh --styles-only` and **writes**.
  A style authored on one machine reaches the other's `~/.claude` with nobody running anything.
  Safe unattended because it copies prose out of a store that already owns it, backs up before
  overwriting, refuses on its own to clobber a style this machine did not install, and touches
  no network and no git.
- `machine-config.sh` → `session-check.sh` runs `apply.sh --check --settings-only` and only
  **reports**. Settings rewrite `settings.json`, which is wider than an unattended hook should
  take on itself.

The `zz-` prefix is load-bearing. The engine runs `session-checks.d/*.sh` in **glob order**, and
the store is synced by a *different* drop-in in the same directory — so an apply that sorts before
that sync reads the store as it was before it, and reports nothing while the update sits on disk
unread. That is the exact bug this drop-in was added to close. Renaming it re-opens it.

**A change to the ACTIVE style asks for a restart, first thing.** The session read its style file
before the hook fired, so it is now following prose that is no longer on disk. `session-apply.sh`
resolves the running style (project-local, then project, then user `outputStyle`) and, on a match,
says `RESTART` in the banner fragment — the point being that the user restarts *before* working
under stale rules rather than after. A style they are not running is reported without the alarm.

On a refusal it names **both** exits — `--promote` to publish yours, `--force` to take theirs —
and explicitly does not choose, because the local copy is often the newer work, which is exactly
why it was not overwritten.

**Exit status**: `0` clean · `1` drift under `--check` · `2` usage · `3` applied what it could and
**refused** at least one thing `shared/` asked for. `--check` returns the status the real run
*would* — refusal first — because a dry run that disagrees with the real run is worthless twice
over. A refusal that exited `0` would be
indistinguishable from a clean apply, which is the fail-open shape this whole store guards against.

`scripts/test-apply.sh` is the gate — this repo runs no CI, so the fixture pass is what makes the
guards real. Every one of them was proven red by breaking the subject, never the assertion.

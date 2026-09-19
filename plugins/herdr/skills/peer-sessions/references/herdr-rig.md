# Rigging a herdr fleet — flags, placement, teardown, and by hand

Read this when you pick a `spawn-fleet.py` placement, need a flag `SKILL.md` does not name, write a teardown by hand, or need a layout the script does not wrap: an unusual layout, a recording, a fork of an existing conversation, one worktree per peer, or a herdr capability it does not expose.

`$PS` below is `$(readlink ~/.claude/skills/peer-sessions)/scripts` — the checkout path differs per machine.

## Every `spawn-fleet.py` flag

- `--placement split|tab|workspace` — which herdr level holds the fleet
  (default `workspace`)
- `--direction right|down` — direction of each new pane. Default `right`. A third
  and later pane alternates, so three panes do not end up as three slivers. Naming
  the flag turns the alternation off and the direction is then obeyed exactly.
- `--focus` / `--no-focus` — move the interface to the fleet, or leave it alone.
  Default: `--no-focus` for `split`, `--focus` otherwise.
- `--per-group 1|2` — sessions per tab or per workspace (default 2). Ignored by
  `split`.
- `--prefix <name>` — label prefix for each new tab or workspace (default `fleet`,
  so labels read `fleet-1`, `fleet-2`)
- `--mkdir` — create a working directory that does not exist. Without it, a missing
  directory is an error, so a typo cannot quietly become an empty directory.
- `--model <model>` — model for every session in the fleet
- `--claude-arg <flag>` — repeatable, passed to `claude` verbatim. The escape hatch
  for anything this script does not wrap.
- `--timeout <seconds>` — how long to wait for live messaging sockets (default 120)
- `--permission-mode <mode>` — default `auto`. Read the permission section of
  SKILL.md before you change it, and never set a bypass mode.

herdr splits only `right` and `down`. There is no `left` or `up`, and there is no
window level over the herdr command-line interface, so a `--placement window` from
some other multiplexer has no equivalent here.

## Choosing a placement

**`split`** puts each peer in a pane beside your own, chained off
`$HERDR_PANE_ID`. The fleet is in sight, which suits a demo or a short fan-out you
want to watch. It defaults to `--no-focus` so the user's keystrokes stay in the
user's own pane. More than three panes beside one pane get too thin to read; the
script says so on stderr and points you at the other placements.

Its teardown closes the new panes only. **The workspace belongs to the user.**

**`tab`** puts each group of peers in a new tab of your current workspace. This is
the best default for a real fleet of three or more: each peer gets a full-width
pane, the tab strip names the groups, and one `herdr tab close` per tab cleans up.
It needs `$HERDR_WORKSPACE_ID`.

**`workspace`** puts each group in its own workspace. Use it when the fleet's work
is unrelated to what the user has open, or when the fleet is large enough that its
tabs would crowd out the user's own. This is the default because it never touches
anything the user already had.

## Focus

`--focus` on `tab` or `workspace` focuses the **first** group only. Focusing every
group in turn would walk the interface across the whole fleet while the sessions
are still starting.

Prefer `--no-focus` whenever the user is typing. A focus change moves their next
keystroke into a peer's prompt.

## Teardown syntax

Teardown is off by default. `spawn-fleet.py` prints the block with real
identifiers. Write it by hand only when you must:

```bash
kill <pid> <pid>                   # always first; the pids come from the spawn report
                                   # or from peer-addr.py

herdr pane close <pane_id>         # --placement split, one call per pane
herdr tab close <tab_id>           # --placement tab, one call per tab
herdr workspace close <ws_id>      # --placement workspace, one call per workspace

python3 "$PS/peer-addr.py"    # confirm gone
```

**Kill the processes first.** Closing a herdr surface does not stop the `claude`
running in it. Close the pane and you lose the way to see the session, not the
session.

If the spawn report shows no pid — a peer stuck on a trust prompt has not
registered yet — read it off the pane instead:

```bash
herdr pane process-info --pane <pane_id>
```

The reply carries `foreground_processes[].pid` and the full `argv`, so you can
confirm the pid belongs to the peer you mean before you signal it.

Never close a surface you did not create. With `--placement split` that means the
panes and nothing above them.

## The herdr object model

A **workspace** holds tabs. A tab holds panes. A pane holds one terminal, and a
terminal may host a recognised **agent**.

Identifiers are opaque and durable: `wE` for a workspace, `wE:t1` for a tab,
`wE:p4` for a pane. herdr never reuses one after a close. Hold them as long as you
like — unlike a positional pane number, a herdr identifier cannot come to mean
something else behind your back.

The one exception: `herdr pane move` gives the moved pane a new
workspace-qualified identifier. Continue from `.result.move_result.pane.pane_id`
after a move.

herdr injects these into every pane:

```
$HERDR_ENV=1          $HERDR_WORKSPACE_ID   $HERDR_TAB_ID
$HERDR_PANE_ID        $HERDR_SOCKET_PATH
```

Prefer `--current` or an explicit identifier over omitting a target. An omitted
target can land on another client's focused pane.

## Where am I?

```bash
herdr pane current --current
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
```

`herdr api snapshot` returns the whole layout in one call, which beats three
listings when you want the shape of everything at once.

## A peer beside your own pane

Two steps, always in this order. `agent start` never creates or moves layout — it
needs a pane that already exists and sits at an interactive prompt.

```bash
herdr pane split --current --direction right --cwd /tmp/lab/alpha --no-focus
# → {"result":{"pane":{"pane_id":"wE:p4", …}}}

herdr agent start alpha --kind claude --pane wE:p4 \
  -- --name alpha --permission-mode auto
```

Two things to note. `--cwd` on the split means you never type a `cd` into the new
shell. And the arguments after `--` go to `claude`, so `--name alpha` is what makes
the peer addressable — keep it equal to the herdr agent name, or you end up with
two different names for one session.

Retry `agent_pane_busy` for a few seconds. herdr needs a moment to settle a new pty
before the pane counts as an available shell.

## A group of peers in one tab

```bash
herdr tab create --workspace "$HERDR_WORKSPACE_ID" \
  --cwd /tmp/lab/alpha --label fleet-1 --no-focus
# → {"result":{"tab":{"tab_id":"wE:t3"},"root_pane":{"pane_id":"wE:p6"}}}

herdr agent start alpha --kind claude --pane wE:p6 -- --name alpha --permission-mode auto
herdr pane split --pane wE:p6 --direction down --cwd /tmp/lab/beta --no-focus
herdr agent start beta  --kind claude --pane wE:p7 -- --name beta  --permission-mode auto
```

`workspace create` has the same shape and returns `.result.workspace`,
`.result.tab` and `.result.root_pane` together. Both give you a root pane with a
shell already in it, so the first peer needs no split.

Split a wide pane `right` and a tall pane `down`, and avoid chaining several splits
in one direction — three panes split the same way are three slivers. `--ratio` sets
an uneven division when one peer's output deserves more room.

## Watching a peer

```bash
herdr agent get  alpha
herdr agent read alpha --source detection --lines 40
herdr agent wait alpha --until idle --until blocked --timeout 120000
```

`herdr agent get` is the honest signal; the `agent_status` table, and why `agent read` recovers little from an alternate-screen agent, are in `troubleshooting.md`. Pass both `--until` states — waiting only for `idle` on a peer that hits a prompt burns the whole timeout. If you asked for a reply over `SendMessage`, do not wait at all: end your turn.

## Handing a peer back to the user

```bash
herdr agent focus alpha              # put the user in front of it
herdr agent attach alpha --takeover  # take the terminal over
herdr agent send-keys alpha esc      # keys are validated before any byte is written
```

`focus` is the right move for a blocked peer. Do not answer a permission or trust
prompt on the user's behalf.

## One worktree per peer

A fleet that edits one repository will collide unless each peer gets its own
checkout. Two routes:

```bash
herdr worktree create …              # a herdr workspace backed by a git worktree
claude --worktree                    # claude makes its own, per session
```

herdr's route gives the worktree a workspace in the interface, which suits a fleet
you want to watch. `claude --worktree` needs no herdr concept at all. Check the
spelling of both in their own help before you use them.

## Forking one conversation into several peers

`--fork-session` starts a peer from an existing conversation's history under a
**new** session id:

```bash
claude --resume <sessionId> --fork-session --name reviewer-a --permission-mode auto
```

The fork opens with the full transcript and a fresh identity, the original carries
on, and you can address both. Without `--fork-session`, `--resume` reuses the same
id and the two sessions collide.

To fork one session several ways beats writing the same long brief several times.

Session id and socket are different things. The socket (`uds:…`) addresses a running
**process**. The session id names a **conversation on disk**. Get your own from
`peer-addr.py --me`. Get a peer's from `agent_session.value` in
`herdr agent get <name>`, which is exactly how `spawn-fleet.py` joins a herdr agent
to its `claude` registry record.

## Environment per peer

```bash
herdr pane split --current --direction down --cwd /tmp/lab --env LAB_ROLE=reviewer
```

`--env` works on `pane split`, `tab create` and `workspace create`. Use it for a
standing fact a peer needs from the start, instead of putting it in every brief.

## claude flags worth knowing for a fleet

- `--add-dir` — a second writable directory
- `--model`, `--effort` — cheap workers beside one expensive reviewer
- `--agent`, `--append-system-prompt` — a standing role, so no brief repeats it
- `--permission-mode` — `auto` for a fleet; never a bypass mode (gate 3 in `troubleshooting.md`).

## When this file does not cover it

Read the help. Do not guess, and do not assume something is impossible.

```bash
herdr --help
herdr agent help start        # nested help needs this form
herdr --skill                 # herdr prints its own agent skill
COLUMNS=200 claude --help
```

Never run bare `herdr` — it launches the interactive interface. Never probe a
mutating subcommand with its arguments left off: `herdr workspace create` with no
arguments does not print help, it creates a workspace.

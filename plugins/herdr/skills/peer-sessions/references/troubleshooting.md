# Troubleshooting peer messages and herdr fleets

Read this when a send fails, a peer stays silent, or a session you can see refuses
to be addressed.

Start here, always:

```bash
python3 "$(readlink ~/.claude/skills/peer-sessions)/scripts/peer-addr.py"
```

It lists every live session on the machine and gives a reason for each one you
cannot reach. Most of the questions below are answered by that one line of output.

## The four gates

A message passes four gates. Find the one that stopped you instead of guessing.

1. **Your own permission classifier.** `SendMessage` is a tool call, and it can be
   denied before the message leaves. This happens most with briefs that tell a peer
   to run shell commands. If the call is denied, tell the user. Do not reword the
   brief to get past the denial.
2. **Name resolution.** A name that does not resolve returns an error that carries
   the `[ref]` you need. That is a confirmation step, not a fault. Copy the ref and
   send again. A ref you did not just read from a listing or an error is stale and
   will not resolve.
3. **The receiver's inbound gate.** A receiver with bypassed permissions **holds**
   inbound peer messages for human approval. They park where the model never sees
   them, and no error comes back to you. This is why a fleet starts in `auto` mode.
4. **The judgement of the receiving model.** The peer reads the brief and can
   decline. A refusal still returns `success: true`. That flag means the message
   arrived. It says nothing about what the peer did with it.

Gate 4 is a feature. Every peer message carries a trailer saying the sender holds
none of the user's authority. Asking a peer to do what your own session was denied
is permission laundering, and refusing is the correct answer in both directions.

## The peer is up, but nothing you send arrives

Work down this list.

**The folder-trust prompt.** The commonest cause by far. `claude` records trust per
**exact** directory path in `~/.claude.json`, under
`projects.<abspath>.hasTrustDialogAccepted`, and a subdirectory does **not** inherit
its parent's trust. A peer started anywhere untrusted stops on the trust prompt
before it registers a messaging socket. `herdr agent get <name>` reports
`agent_status: blocked`, and `spawn-fleet.py` names the prompt for you.

There is no fix from this side, and you must not press the button for the user.
Either spawn the fleet in directories the user already works in, or hand them the
list of panes to answer. `herdr agent focus <name>` puts them in front of one.

**The version wall.** Peer messages shipped in `claude` **2.1.224**. An older build
makes no socket, so the session is alive, healthy and invisible.
`claude --resume <sessionId>` in a fresh pane repairs it and keeps the history.

**A correct version is necessary, not sufficient.** A session on 2.1.224 or newer
with no socket means the messaging gate is off, the bind failed, or the session is
thin or bare.

**Your harness may scope messages more narrowly.** Everything above assumes
`SendMessage` is backed by the generic cross-session protocol — a
`CLAUDE_CODE_MESSAGING_SOCKET` in your own environment, and sessions discoverable
through `~/.claude/sessions/*.json`. Some harnesses instead implement
`SendMessage` against their own orchestration layer, where the only reachable names
are agents that harness itself spawned. The signs are specific:

- `peer-addr.py --me` reports no socket **for your own session**, not just a peer's.
- A peer well past 2.1.224, confirmed up by `herdr agent get`, returns
  `No agent named 'X' is reachable` — a different error from the documented
  re-send-with-the-ref bounce, and a different mechanism.
- No `ListAgents` tool exists at all.

If you see that, stop resending. No version fix changes it. Tell the user their
harness scopes messages to its own spawn mechanism, and drive the fleet with
herdr's own commands instead:

```bash
herdr agent prompt <name> "<brief>" --wait --timeout 120000
herdr agent wait  <name> --until idle --until blocked --timeout 120000
herdr agent read  <name> --source recent-unwrapped --lines 120
```

Say plainly that this is a one-way channel with manual polling, and not the
reply-as-a-new-turn behaviour SKILL.md describes.

## The peer is silent after a successful send

1. **It still works.** Research plus writing runs for minutes. The reply arrives as
   a new user turn. End your turn. This is correct, not lazy.
2. **It is blocked.** `herdr agent get <name>` and read `agent_status`. A blocked
   agent waits for a human and will wait forever.
3. **You never asked for a reply.** A send is one way. If the brief carried no ask,
   nothing comes back.
4. **It declined.** Read the pane. Peers state their refusals.

## Do not scrape the screen to tell busy from stuck

`claude` draws on the alternate screen. Those rows never enter the host's
scrollback, so `herdr pane read` and `herdr agent read` often recover nothing
useful, and a thinking session looks exactly like a waiting one.

Use `herdr agent get <name>` instead. `agent_status` is herdr's own classification:

| `agent_status` | What it means |
| --- | --- |
| `working` | busy. Wait. |
| `idle` | up and ready, and its tab was seen in the focused interface |
| `done` | the same ready state, after work finished that nobody watched |
| `blocked` | herdr recognised an approval or a question. A human must answer. |
| `unknown` | an agent is present but herdr cannot classify it. **Not** proof that it finished. |

`--source detection` is the one read that is reliably useful on an alternate-screen
agent, because it is the buffer herdr itself classifies from. That is how
`spawn-fleet.py` names which prompt a blocked peer stopped on.

When you truly need a peer's long output, do not fight the screen. Ask the peer to
write Markdown to a file, and read the file.

## Error codes

- `ENOENT` or `ECONNREFUSED` — the peer restarted and the socket path is stale. Run
  `ListAgents` or `peer-addr.py` again for the current path.
- `EBUSY` — the peer is alive and the pipe is busy for a moment. Retry the same
  address.
- A socket file that exists but never answers — the peer crashed without cleaning
  up. A leftover `~/.claude/sessions/<pid>.json` means a crash; a normal exit
  unlinks both files.

## herdr traps

- **`agent_pane_busy` right after a split.** A pane that `pane split` or
  `workspace create` just returned is not always an available shell yet, because
  herdr is still settling the new pty. `spawn-fleet.py` retries this one error for
  a few seconds. Do the same by hand rather than treating one failure as final.
- **`agent start` never changes the layout.** It needs a pane that already exists
  and sits at an interactive prompt. Split first, then start.
- **Agent names are constrained and unique.** `[a-z][a-z0-9_-]{0,31}`, and no two
  live agents may share one. Note that an auto-detected `claude` session is
  labelled `claude`, so that name is usually already taken.
- **`interactive_ready` is often absent.** It is a real field on herdr's
  `AgentInfo`, but herdr omits it for an agent it did not start, so a plain
  truthiness test on it fails for reasons that have nothing to do with readiness.
  Never make it the gate. Gate on the messaging socket, and read `agent_status`
  for diagnosis.
- **`herdr agent read` prints text, not JSON.** Every other subcommand answers with
  JSON. Do not pipe this one into a JSON parser.
- **Check the `error` key, not the exit code.** herdr answers with JSON either way:
  `result` on success, `error` on failure, and a server error goes to **stderr**
  with exit 1 while a syntax error exits 2. Read both streams.
- **There is no window level.** `herdr --help` exposes `workspace`, `tab` and
  `pane`. A layout idea that needs an operating-system window has no herdr command.

## claude command-line traps

- `claude agents` needs a terminal. Use `claude agents --json` in a script. The
  list includes your own session, so check the pid before you signal anything.
- `logs`, `stop` and `attach` are not `claude` subcommands. `claude` reads an
  unknown word as a prompt and starts work on it. Use `kill <pid>`.
- Read the help rather than guess, and remember that flags move between versions:

```bash
COLUMNS=200 claude --help     # a pipe into head kills it with SIGPIPE
```

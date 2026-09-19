# Peers that are not claude

Read this when a fleet should include an agent of another kind — a second opinion
from a different model, or a tool that suits one job better than `claude` does.

herdr starts many kinds of agent in a pane:

```
pi codex gemini cursor devin agy cline omp mastracode opencode copilot
kimi kiro droid amp grok hermes kilo qodercli maki
```

`herdr agent start <name> --kind <kind> --pane <id>` is the same command for all of
them. The layout side of a mixed fleet costs nothing extra.

**The messages are the part that changes.** Cross-session peer messages are a
`claude` feature. A `codex` or `gemini` agent registers no socket in
`~/.claude/sessions/`, so `ListAgents` never lists it, `SendMessage` cannot address
it, and `peer-addr.py` cannot see it. None of that is a fault to debug.

`spawn-fleet.py` starts `claude` peers only, on purpose: its whole readiness check is
the messaging socket, which a non-`claude` agent will never have. Start those by
hand.

## Starting one

```bash
herdr pane split --current --direction down --cwd /tmp/lab/review --no-focus
# → {"result":{"pane":{"pane_id":"wE:p8", …}}}

herdr agent start reviewer --kind codex --pane wE:p8
```

Arguments after `--` go to that agent's own command line, so check its help rather
than assume `claude`'s flags carry over. Retry `agent_pane_busy` for a few seconds,
the same as for a `claude` peer.

## Driving one

herdr's own commands are the whole channel:

```bash
herdr agent prompt reviewer "<brief>" --wait --timeout 120000
herdr agent wait   reviewer --until idle --until blocked --timeout 120000
herdr agent read   reviewer --source recent-unwrapped --lines 120
```

Three differences from a `claude` peer matter, and you should say them to the user
rather than let the difference show up as apparent silence:

1. **It is one way.** Nothing arrives as a new user turn. You poll, or you wait.
2. **You must read the answer yourself.** `agent read` returns plain text, and you
   read it in your own context. A long answer costs you the tokens a peer reply
   would not have.
3. **`--wait` is not a completion signal.** It returns at the first settled
   `idle`, `done` or `blocked`. From a non-working state it returns
   `agent_prompt_stalled` if nothing changes within about five seconds.

Because of point 2, keep briefs to non-`claude` peers narrow and ask for a short,
shaped answer. The alternate-screen problem applies here too: if the reply will be
long, tell the agent to write it to a file and read the file instead.

## When to bother

A mixed fleet earns its cost when the **difference** is the point: a second model
reviewing the first one's work, or a tool that owns a job the others do not. A
mixed fleet purely for throughput is worse than a `claude` fleet, because you give
up the reply-as-a-new-turn behaviour and pay for every answer in your own context.

Every rule in SKILL.md about authority still holds. An agent of another kind holds
none of the user's authority either, and routing a denied action through one is the
same laundering it would be through a `claude` peer.

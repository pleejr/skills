---
name: statusline
description: This skill should be used to install, change, diagnose or remove the Claude Code status line this plugin ships — the bar under the prompt showing model, directory, context-window percentage in colored bands, the 5-hour and 7-day subscription windows, a spinner while shell work is in flight, how long the session has been waiting on you, and an opt-in AWS SSO session clock that renews itself in the final hour. Covers the wiring that enabling the plugin cannot do (Claude Code allows one statusLine and no plugin may provide it), what each segment means, why a segment is missing rather than broken, and how to hand the statusLine back to a script that was there before. Triggers "install the status line", "wire up the statusline plugin", "my status line is blank", "why is there no ctx percentage", "what does the spinner in the status line mean", "the idle timer is stuck", "why is the sso segment red", "the sso countdown is wrong", "show my AWS SSO session in the status line", "turn the status line off", "put my old status line back", "point the status line at the new version". Distinct from `snapshot` (which snapshots whatever settings.json says, including this) and from Claude Code's own `/statusline` setup command, which writes a fresh script rather than wiring this one. NOT for authoring an unrelated status line from scratch.
version: 1.0.0
summary: A status line showing model, directory, context bands, the 5h/7d subscription windows, a spinner while shell work runs, the idle timer, and an opt-in AWS SSO session clock — plus the wiring script a plugin needs because Claude Code allows only one statusLine and no plugin can provide it.
---

# statusline — the bar under the prompt, and the wiring it needs

Claude Code allows exactly **one** `statusLine`, and a plugin cannot provide it: a plugin's own
`settings.json` supports only `agent` and `subagentStatusLine`. So enabling this plugin is not the
wiring — `scripts/wire.sh` is. Everything else the plugin needs (the idle stamp) does come from
`hooks/hooks.json`, and needs nothing by hand.

## Wiring

```bash
S="${CLAUDE_PLUGIN_ROOT:-<skills clone>/plugins/statusline}/skills/statusline/scripts"
"$S/wire.sh" status                 # what is wired right now
"$S/wire.sh" wire                   # point settings.json here (refreshInterval 1)
"$S/wire.sh" wire --padding 2       # ...with extra indentation
"$S/wire.sh" unwire                 # restore what was there before, or remove the key
```

`wire` writes `CC_STATUSLINE=pleejr "<path>/statusline.sh"`. The **marker, not the path**, is what
says the entry is ours: the install path carries the plugin version, so it moves on every update
and the SessionStart hook's `wire.sh heal` follows it. A `statusLine` without the marker belongs to
someone else and is never rewritten or removed — `wire` replaces it only because you asked, saving
it first so `unwire` puts it back attribute for attribute. Every write backs settings.json up
first, and `heal` exits 0 whatever it finds, so it can never block a session start.
`STATUSLINE_HEAL=0` turns the self-heal off.

## What the segments mean

`Opus 5 | repos | ctx 42% | 5h 12% | 7d 71% | sso 5h12m | ⠙ 2 running | ⏳ idle 3m07s`

- **ctx** — context-window usage. Green below 70%, amber from 70% with `distill soon`, red from
  85% with `distill now`. Truncated, never rounded, so 84.9% cannot escalate a band.
- **5h / 7d / spend** — subscription usage from `.rate_limits`, same bands. The host sends these
  only on a subscription (or behind a gateway reporting a spend limit) and only after the session's
  first API response.
- **sso** — opt-in AWS SSO session clock, off unless both `STATUSLINE_AWS_SSO_SESSION` (an
  `[sso-session]` in `~/.aws/config`) and `STATUSLINE_AWS_SSO_PROFILE` (a profile on it) are set;
  a launcher's `export` reaches the status line.
  - Counts down `STATUSLINE_AWS_SSO_HOURS` (default 8) from the login stamp
    `~/.local/state/claude-statusline/sso-login-<session>`. `scripts/sso.sh login` writes it; so
    does the first passing check after a failed one, which is how a login made elsewhere is seen.
  - `sso.sh check` runs `aws sts get-caller-identity` detached, once per 5-minute window, from a
    scratch HOME so cached role credentials cannot mask an ended session. An auth failure turns
    the segment red; a network fault does not. It is the only source of red.
  - In the final hour it turns amber `renewing` and starts `sso.sh login` detached, once per
    30-minute window; you approve the browser prompt, and the stamp resets on success.
  - Dim `sso ok` when the check passes with no stamp, or past the assumed length. With neither a
    stamp nor a check result yet, nothing. The render reads two files and claims each window with `mkdir`.
- **⠙ N running** — shell work in flight, counted from the process table: children of this
  session's `claude` process started through a shell snapshot. It clears itself when the work ends,
  with no hook to clear a marker.
- **⏳ idle** — how long the session has been waiting on you, from an epoch the Stop hook stamps
  and the UserPromptSubmit hook clears. It ticks once a second because `wire` sets
  `refreshInterval: 1`.

## When a segment is missing

A segment the host did not send is **absent, not broken** — the renderer drops any field that is
null, non-numeric or unsent, because a status line that breaks is worse than one that is not there.
So diagnose in this order:

1. `wire.sh status` — a foreign or absent `statusLine` explains an entirely blank bar.
2. `jq . <<< "$payload"` on a captured payload — no `.context_window` means no ctx segment, and
   that is the host's version, not this script.
3. `command -v jq` — without jq every segment but the model and directory disappears.
4. A stuck **idle** timer means the UserPromptSubmit hook is not firing: check the plugin is
   enabled, then that `${TMPDIR:-/tmp}/.claude-idle-start-<session id>` disappears when you submit.

Tests: `scripts/test-wire.sh` — renderer, idle stamp, wire/unwire round trip, and the refusal to
touch a statusLine that is not ours. No network, no writes outside a temp directory.

---
name: hook-authoring
description: This skill should be used when writing, wiring, widening or debugging a Claude Code lifecycle hook — a PreToolUse gate, a PostToolUse check, a Stop or SessionStart hook, a UserPromptSubmit injector, a settings.json matcher. Feeds it a real captured payload on stdin instead of hand-firing the command, picks the event by what it can actually see (PostToolUse the tool call, Stop the turn end, neither the final prose), reads the matcher as TEXT before the shell expands anything, proves it fires on the must-catch case AND refuses the near-miss, measures what a widened matcher NEWLY matches, and routes output by who can act on it. Every recorded miss failed OPEN — a hook that passes its own tests and guards nothing. Triggers: "write a hook", "add a PreToolUse hook", "run this every time Claude", "why isn't my hook firing", "the hook exits 0 but should block", "my gate denies the wrong thing", "widen this matcher", "does this hook actually work", "hook payload on stdin", "should this block or just warn". Distinct from `prove-the-test-can-fail` (red-before-green on a gate that already exists — this owns payload shape, event capability, matcher scope and channel), the bundled `update-config` (wires settings.json, never proves it fires) and `machine-config` (snapshots/restores hooks). NOT for choosing between a hook and a skill, and NOT for a script that never ran as a hook.
version: 1.0.0
summary: Author a Claude Code lifecycle hook that actually fires — capture a real payload and feed it on stdin, pick the event by what it can see, read the matcher as text, prove both the catch and the refusal, and route output by who can act on it.
tags: [craft]
---

# hook-authoring — a hook that passes its own tests is not a hook that works

Every recorded miss in this practice **failed open**: the hook ran, exited 0, and guarded nothing. A heredoc program ate the payload and the fail-open handler returned success. A `Stop` gate graded the previous reply while passing its own suite. A `grep` whose pattern did not parse returned exit 2, which the handler read as "no matches". A gate denied the one directory the operation deliberately was not in.

Fail-open is the default failure because a hook's error path and its all-clear path are the same exit code. So the question is never "does it run" — it is **what does it do when it is wrong**, and the only evidence is a run against a real payload and a case that must be refused.

Version-pinned throughout: the measured behaviours below were taken on Claude Code 2.1.231. Re-measure on the current build before relying on one.

## Run this when

- Writing a new hook, or a new matcher, for any lifecycle event.
- A hook fires and does nothing, or does not fire at all.
- **Widening** an existing matcher or permission glob — the widened set is the risk, not the case that prompted it.
- Choosing between blocking the turn and injecting context.
- A hook's own self-test passes and the behaviour in session disagrees.

## 1. Capture a real payload before writing a line of the hook

Claude Code delivers the event as **JSON on the hook's stdin**. A hook written against an imagined payload is a hook written against the wrong field names.

```bash
# Wire this as the hook first; work one session; then read the file.
cat > ~/.claude/hooks/capture.sh <<'EOF'
#!/usr/bin/env bash
cat >> /tmp/hook-payload.jsonl
exit 0
EOF
chmod +x ~/.claude/hooks/capture.sh
```

Every later test feeds one captured line back in: `./my-hook.sh < <(sed -n '3p' /tmp/hook-payload.jsonl)`. That is the fixture. Everything downstream is asserted against it.

### The stdin collision

The payload arrives on stdin, so an interpreter told to read its **program** from stdin consumes the payload:

```bash
python3 - <<'PY'      # WRONG — the program is on stdin, json.load(sys.stdin) hits an exhausted stream
import json, sys
d = json.load(sys.stdin)
PY
```

`json.load` raises, the fail-open handler exits 0, and the hook has silently stopped guarding. Pass the program as an argument instead:

```bash
PYSRC=$(cat <<'PY'
import json, sys
d = json.load(sys.stdin)
PY
)
exec python3 -c "$PYSRC"
```

Same collision for `sh -s`, `ruby -`, `node -`, `jq -f -`. Prefer a real script file over any inline program when the hook is more than a few lines.

## 2. Pick the event by what it can see

An event that cannot observe the thing being checked cannot be made to by better code.

| Event | Sees | Can |
| --- | --- | --- |
| `SessionStart` | session start, source (`startup`/`resume`) | inject context, show the user a message |
| `UserPromptSubmit` | the prompt about to be sent | inject context, block the prompt |
| `PreToolUse` | the tool name and its **input**, before execution | deny the call |
| `PostToolUse` | the tool call and its result | feed the model back, not undo |
| `Stop` | the turn is ending | park a verdict; **not** read the turn's final message |
| `SessionEnd` | the session closing | write artifacts; nothing reaches the model |

**Neither `PostToolUse` nor `Stop` can see the final prose.** `Stop` reads `transcript_path` **one message behind** — Claude Code writes the turn's final message *after* Stop hooks return. Measured: at Stop the transcript tail was a `user` tool-result at index 720, the newest assistant text at 703. Polling cannot see a write that happens after return, and a check that demands a "fresh" message passes its own tests and fails open on every turn.

So a check that needs the current reply belongs in the **model's instructions**, not a hook. If the lag is acceptable, ship it and say so: grade the newest matching message, memoise its digest per session, and open the feedback with "in your PREVIOUS reply". The uncovered case is the last reply of a session — state that rather than pretending it is covered.

Confirm the field names for the event in the docs (`code.claude.com/docs/en/hooks.md`) against the captured payload, not from memory.

## 3. The matcher, and the hook, see TEXT — before the shell expands anything

A `PreToolUse` hook receives the command **as the model wrote it**, not as the shell will run it. Every path it extracts is a literal token.

- `git -C "$W" commit` hands the hook the four characters `$W`. A gate that resolves a non-absolute path against the session `.cwd` gets `<cwd>/$W`, which does not exist, walks up to the nearest real directory — the primary checkout — and denies the command **for being in the primary**, which is exactly where the operation was not.
- `.cwd` is the session's working directory **as tracked before the call**. A `cd` inside a compound command never reaches it; a `cd` from an *earlier standalone call* does, and then persists. So a command aimed at repo A is denied for being in repo B.
- Flags that take an argument are where extractors fail **open**: `git -C <primary> checkout` slips through an extractor that expects the path in a fixed position.

**How to apply, on both sides.** Writing a command a hook will read: pass a literal absolute path (`git -C /Users/.../repo-worktree commit -F <file>`), and move the session cwd with a standalone `cd` when a run spans one tree. Writing the hook: normalise before matching, and enumerate the flag forms rather than assuming a position.

The variable form is the natural one to write, so a note saying "use the literal path" does not survive contact. The literal path goes into the command from the start, not after a denial.

### Widening a matcher

Measure what the new pattern **newly matches**, not that it now catches the case in hand. Run old and new patterns over the same corpus — the captured payload log, a directory listing, `git log` subjects — and diff the two match sets. The delta is the change. A widened permission glob is reviewed the same way.

### An unparsed pattern is not an absence

A pattern assembled by interpolation can end up with an **empty alternative** — `(~|)/` when one branch expanded to nothing. `grep -E` calls that malformed and exits **2**:

```sh
$ printf 'a/b\n' | grep -E '(~|)/' ; echo "exit=$?"
```

Exit 1 is no match. **Exit 2 is the question never asked.** They are one apart and both print nothing, and a hook that suppresses stderr and treats non-zero as "nothing matched" converts a broken pattern into a clean negative. Check for 2 separately wherever a pattern is built rather than literal, and keep a **known-positive fixture** running through the same pattern — if the positive stops matching, the pattern is broken, not the population empty.

## 4. Route the output by who can act on it

Three channels, and they are not interchangeable:

- **stdout, exit 0** → goes to the **model's** context in a system-reminder. Invisible to the user.
- **stderr, exit 2** → shown to the **user**, rendered under a `hook error` heading. Blocks where the event supports blocking.
- **JSON `{"systemMessage": "..."}` on stdout, exit 0** → shown to the user with no error heading. The clean user-facing channel. (`hookSpecificOutput.additionalContext` is model-only; `initialUserMessage` injects a fake first user turn; `sessionTitle` only sets the title.)

Pick by **who can act on the message**, not by how important it is. A correction aimed at the model, delivered by blocking the turn, spends the operator's attention on something they cannot do anything about — and if the check grades one message behind, the interruption is always about a reply already sent.

The shape that works for a model-facing verdict: the `Stop` half writes the verdict to a per-session file and exits 0; the `UserPromptSubmit` half drains that file into context next turn and deletes it. Enforcement is unchanged — the model is told one turn later, which was the earliest it could act either way — and the operator sees nothing. **The lag stops being a cost the moment the channel changes.**

Two corollaries:

- Never restate in a verdict what the same hook already injects every turn. Carry only what is new.
- When a gate is noisy, check whether it is **wrong** or merely **visible** before loosening the rule it enforces.

## 5. Prove the catch AND the refusal, before wiring

Write the self-test before the hook is wired, and make it assert a **red**:

1. **The must-catch case** → hook exits with the blocking status and the message names the right thing.
2. **The near-miss** → something that merely resembles the subject; hook must let it through.
3. **The case it always denied** → still denied, after any edit. A widened gate that stops denying its original subject is the fail-open regression.
4. **A positive control on every pattern** → if the known-good input stops matching, the pattern broke.

Run the suite against the **post-edit file**, from a throwaway fixture directory, before the file lands. `briefing-gate.sh` was caught this way: its own `selfcheck` printed `BROKEN: expected exit 2 on an over-length bullet, got 0`.

Keep the fail-open catch — a crashing hook should not brick the session — but make the suite assert that the guarded path actually goes red. A fail-open handler with no red in its suite is indistinguishable from no hook at all.

For the red-before-green discipline on a gate that already exists, hand off to `prove-the-test-can-fail`; this skill stops where that one starts.

## 6. Wiring, and why hand-firing proves nothing

**Running a hook's command by hand verifies the command, not the hook.** Measured on 2.1.231: a `SessionEnd` hook with no explicit `timeout` is aborted after about one second — `sleep 1.0` completes, `sleep 1.5` is cancelled, `sleep 3` with `"timeout": 30` completes. A capture script needing 3.14s from a 67-repo workspace root was cancelled every real session while every hand run passed. Give any hook that can exceed a second an explicit `timeout`.

Verify by **ending a session and reading the artifact, from the directory the work actually happens in** — not from a convenient one that takes a fast path.

**Count the wiring; do not re-run it.** A helper that appends to every entry whose matcher equals the request will add the command twice when an event holds two groups with the same matcher, and a re-run is a silent no-op whose `--check` reports the duplicated state as correct.

```bash
jq '[.hooks.<Event>[].hooks[].command | select(test("<fragment>"))] | length' ~/.claude/settings.json   # expect 1
jq -r '.hooks | to_entries[] | .key as $e | [.value[].hooks[].command] | group_by(.)
       | map(select(length>1)) | .[] | "\($e): \(length)x \(.[0][0:80])"' ~/.claude/settings.json
```

Matcher-less events are where duplication accumulates, because every tool that adds a group adds another match-all one. Sweep every event after wiring one — "I found it in the place I was looking" is not a finding about the machine.

## 7. The hard safety rule — never spawn `claude` from a hook without a re-entry guard

**A hook's trigger and its spawn are the same event.** A `SessionEnd` hook that ran `claude -p` produced a child whose exit re-fired `SessionEnd`, which spawned another — roughly 13,700 sessions before it was caught. The danger is structural, not a fear of headless `claude`; the target is **detecting recursion and runaway agent generation**.

A deliberate headless spawn is legitimate when bounded. A human- or cron-initiated `claude -p` one-shot, or a subagent, is fine provided it:

1. carries a **re-entry sentinel** — increment `CLAUDE_SPAWN_DEPTH` and refuse above a small N;
2. is **concurrency-bounded** — a lockfile or a count cap;
3. **terminates** — no self-requeuing watch loop.

A hook may spawn `claude` **only** if it also cannot fire on an event its child can re-trigger *and* carries the sentinel.

**Deterministic hooks need no guard.** `git`, file writes, `curl` cannot recurse into `claude`; wire them freely. Ingest, refresh, checkpoint and distill still default to in-session and on-demand — automate them headlessly only under the three conditions above.

## 8. Publishing a hook — check for a draft window

A repo with a scheduled autosave that commits and **pushes to `main`** has no saved-but-private state: editing a file there is publishing it. Mid-rewrite, after two of three edits and before any syntax check, a `chore: sync configs` commit picked up a half-written gate and pushed it to the branch a restore installs from.

The clean tree is the trap. Everywhere else a dirty tree means unsaved work; here a clean tree after an edit means the edit is already on `main`. `git log -1 --stat` is the reliable read, not `git status`.

Author hook changes **outside** such a repo — in a scratch directory — test them there, and copy the finished file in as one move. Expect to fix forward, not amend.

## 9. Checklist

- [ ] A real payload captured and used as the test fixture.
- [ ] No interpreter reading its program from stdin.
- [ ] The event chosen can actually observe the subject; the `Stop` lag stated if relied on.
- [ ] Matcher tested against the literal command text, including `"$VAR"` and flag-argument forms.
- [ ] A widened matcher diffed old-vs-new over a corpus; the delta reported.
- [ ] Every assembled pattern checks `$?` for 2 and has a positive control.
- [ ] Output channel chosen by who can act; model-facing verdicts parked and injected, not blocked.
- [ ] Suite asserts a real red on the must-catch case, a pass on the near-miss, and the original denial still standing.
- [ ] `timeout` set on anything that can exceed a second; verified by ending a real session from the working directory.
- [ ] Wiring counted with `jq` (expect 1), every event swept.
- [ ] No `claude` spawn without a re-entry sentinel, concurrency bound and guaranteed termination.
- [ ] If the target repo autosaves to `main`, the file was authored and tested outside it.

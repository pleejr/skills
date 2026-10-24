import type { Register } from 'claude-code'

// A handed-over command: a line that starts with `! `, optionally wrapped in backticks.
const BANG = /^\s*`?(!\s*\S.*?)`?\s*$/
// The same command as an inline code span anywhere in a line, such as a bullet
// or a Decision option: `` `! cmd` ``. The space after `!` is required here, so
// `!important` or `!=` in code prose is not one, and neither is a bare `!`.
const SPAN = /`(!\s+[^`\s][^`]*)`/g
// A fenced shell block opens with ```sh, ```bash, ```zsh or ```shell; any ``` closes it.
const SHELL_FENCE = /^\s*```\s*(?:sh|bash|zsh|shell)\s*$/i
// An unlabelled block: its one command counts when it starts with `!` or runs a script.
const BARE_FENCE = /^\s*```\s*$/
const FENCE = /^\s*```/
// Any inline code span, for a script run handed over without its `!`.
const CODE = /`([^`]+)`/g
// A script run: a path to a script, optionally after its interpreter. The path is
// absolute, home- or dot-relative, and names a script file or something in a bin/
// folder, so a repo-relative `bin/x.py:143` cited in prose is not one, and neither
// is a bare tool like `terraform plan`.
const SCRIPT_RUN = /^(?:(?:bash|sh|zsh|python3?|node|bun|ruby)\s+)?(?:~|\$HOME|\.\.?)?\/[^\s`]*(?:\.(?:sh|bash|zsh|py|ts|js|mjs|rb)|\/bin\/[^\s/`]+)(?=\s|$)/
// A permission update: the allow-permission.sh handover that unblocks a refused call.
const PERMISSION = /(?:^|[\s/])allow-permission\.sh(?:\s|$)/

function normalize(command: string): string {
  return command.trim().replace(/^!\s*/, '! ')
}

// One command from a block, its `\` continuations joined. A block of several
// commands, or only a comment, is a script to read rather than a command to
// run, so it hands over nothing.
function blockCommand(body: string[]): string | undefined {
  const lines = body.join('\n').replace(/\\\n\s*/g, '').split('\n').map(l => l.trim()).filter(l => l !== '')
  if (lines.length !== 1 || lines[0].startsWith('#')) return undefined
  return lines[0]
}

// The commands a line hands over, in order: the whole line, or its `! ` spans.
function bangsIn(line: string): string[] {
  const whole = BANG.exec(line)
  if (whole && !whole[1].includes('`')) return [normalize(whole[1])]
  return [...line.matchAll(SPAN)].map(m => normalize(m[1]))
}

// Script runs a line hands over in code spans written without a `!`.
function scriptRunsIn(line: string): string[] {
  return [...line.matchAll(CODE)].map(m => m[1].trim()).filter(c => SCRIPT_RUN.test(c)).map(c => `! ${c}`)
}

type Offer = { command: string; explicit: boolean; recommended: boolean }

// The command to offer. A permission update wins outright, since it is what
// unblocks the turn; then a line marked recommended (a Decision block lists its
// recommended option first, so "last" would offer the alternative); then the
// last `!` command; then the last script run written without one. A one-command
// block counts as a line of its own, and is recommended when the line
// introducing it is.
export function lastBang(answer: string): string | undefined {
  const offers: Offer[] = []
  let block: string[] | undefined
  let kind: 'shell' | 'bare' | 'other' = 'other'
  let lead = ''
  for (const line of answer.split('\n')) {
    if (block !== undefined) {
      if (!FENCE.test(line)) {
        block.push(line)
        continue
      }
      const command = blockCommand(block)
      const body = block
      block = undefined
      const recommended = /\brecommended\b/i.test(lead)
      if (kind !== 'other' && command !== undefined && (kind === 'shell' || command.startsWith('!'))) {
        offers.push({ command: normalize(command.startsWith('!') ? command : `! ${command}`), explicit: true, recommended })
      } else if (kind === 'bare' && command !== undefined && SCRIPT_RUN.test(command)) {
        offers.push({ command: `! ${command}`, explicit: false, recommended })
      } else if (kind !== 'shell') {
        for (const l of body) for (const c of bangsIn(l)) offers.push({ command: c, explicit: true, recommended: false })
      }
      continue
    }
    if (FENCE.test(line)) {
      block = []
      kind = SHELL_FENCE.test(line) ? 'shell' : BARE_FENCE.test(line) ? 'bare' : 'other'
      continue
    }
    if (line.trim() !== '') lead = line
    const recommended = /\brecommended\b/i.test(line)
    const bangs = bangsIn(line)
    for (const command of bangs) offers.push({ command, explicit: true, recommended })
    if (bangs.length === 0) for (const command of scriptRunsIn(line)) offers.push({ command, explicit: false, recommended })
  }
  const last = (keep: (o: Offer) => boolean) => offers.filter(keep).at(-1)?.command
  return last(o => PERMISSION.test(o.command)) ?? last(o => o.recommended) ?? last(o => o.explicit) ?? last(() => true)
}

// The command on offer since the last answer. The engine generates its own
// guess at the next prompt a moment after the turn ends, and showing that guess
// replaces this one, so it is dropped until the person submits something.
let offered: string | undefined

export const register: Register = on => {
  on('prompt.suggest', ($, e, next) =>
    e.origin.kind === 'suggestion' && offered !== undefined ? { isShown: false } : next(e))

  on('prompt.submit', ($, e, next) => {
    offered = undefined
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId !== undefined) return done

    const command = e.reason === 'answer' ? lastBang(e.answer) : undefined
    offered = command
    if (command === undefined) return done

    // A suggestion, not a fill: `$.prompt.fill` writes `! cmd` as plain text,
    // so Enter sends it to the model as a message. Taking the suggestion with
    // Tab enters it as typed, and the leading `!` switches the box to shell
    // mode. It shows only in an empty box, so a draft typed during the turn is
    // never touched; it waits for the ending turn to release the box.
    for (let attempt = 1; attempt <= 10; attempt++) {
      const shown = await $.prompt.suggest({ text: command })
      if (shown.isShown) return done
      await $.clock.sleep(200)
    }
    $.ui.toast(`bang-fill: suggestion not shown; copy the command by hand`)
    return done
  })
}

import type { Register } from 'claude-code'

// A handed-over command: a line that starts with `! `, optionally wrapped in backticks.
const BANG = /^\s*`?(!\s*\S.*?)`?\s*$/
// The same command as an inline code span anywhere in a line, such as a bullet
// or a Decision option: `` `! cmd` ``. The space after `!` is required here, so
// `!important` or `!=` in code prose is not one, and neither is a bare `!`.
const SPAN = /`(!\s+[^`\s][^`]*)`/g
// A fenced shell block opens with ```sh, ```bash, ```zsh or ```shell; any ``` closes it.
const SHELL_FENCE = /^\s*```\s*(?:sh|bash|zsh|shell)\s*$/i
const FENCE = /^\s*```/

function normalize(command: string): string {
  return command.trim().replace(/^!\s*/, '! ')
}

// A shell block holding one command, its `\` continuations joined. A block of
// several commands, or only a comment, is a script to read rather than a
// command to run, so it hands over nothing.
function fencedCommand(body: string[]): string | undefined {
  const lines = body.join('\n').replace(/\\\n\s*/g, '').split('\n').map(l => l.trim()).filter(l => l !== '')
  if (lines.length !== 1 || lines[0].startsWith('#')) return undefined
  return normalize(lines[0].startsWith('!') ? lines[0] : `! ${lines[0]}`)
}

// The commands a line hands over, in order: the whole line, or its `! ` spans.
function bangsIn(line: string): string[] {
  const whole = BANG.exec(line)
  if (whole && !whole[1].includes('`')) return [normalize(whole[1])]
  return [...line.matchAll(SPAN)].map(m => normalize(m[1]))
}

// The last handed-over command, unless a line marked recommended carries one:
// a Decision block lists its recommended option first, so "last" would offer
// the alternative. A one-command shell block counts as a line of its own, and
// is recommended when the line introducing it is.
export function lastBang(answer: string): string | undefined {
  let last: string | undefined
  let recommended: string | undefined
  let block: string[] | undefined
  let lead = ''
  for (const line of answer.split('\n')) {
    if (block !== undefined) {
      if (!FENCE.test(line)) {
        block.push(line)
        continue
      }
      const command = fencedCommand(block)
      block = undefined
      if (command === undefined) continue
      last = command
      if (/\brecommended\b/i.test(lead)) recommended = command
      continue
    }
    if (SHELL_FENCE.test(line)) {
      block = []
      continue
    }
    if (line.trim() !== '') lead = line
    const found = bangsIn(line)
    if (found.length === 0) continue
    last = found[found.length - 1]
    if (/\brecommended\b/i.test(line)) recommended = last
  }
  return recommended ?? last
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

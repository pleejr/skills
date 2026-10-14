import type { Register } from 'claude-code'

// A handed-over command: a line that starts with `! `, optionally wrapped in backticks.
const BANG = /^\s*`?(!\s*\S.*?)`?\s*$/

export function lastBang(answer: string): string | undefined {
  const lines = answer.split('\n')
  for (let i = lines.length - 1; i >= 0; i--) {
    const m = BANG.exec(lines[i])
    if (m) return m[1].replace(/^!\s*/, '! ')
  }
  return undefined
}

export const register: Register = on => {
  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId !== undefined || e.reason !== 'answer') return done

    const command = lastBang(e.answer)
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

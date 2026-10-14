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

    // Never clobber a draft typed while the turn ran.
    const box = await $.prompt.read()
    if (box.text.trim() !== '') {
      $.ui.toast(`bang-fill: draft kept; command not filled`)
      return done
    }

    // The box can still be held by the ending turn; retry briefly.
    for (let attempt = 1; attempt <= 5; attempt++) {
      const filled = await $.prompt.fill({ text: command, mode: 'replace' })
      if (filled.isFilled) return done
      await $.clock.sleep(200)
    }
    $.ui.toast(`bang-fill: box refused the command; copy it by hand`)
    return done
  })
}

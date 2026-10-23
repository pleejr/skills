import { test, expect } from 'claude-code/testing'
import { lastBang } from './register'

test('takes the last bang line, backticks stripped', () => {
  expect(lastBang('Run this:\n\n`! bash ~/a.sh`\n\nthen\n! bash ~/b.sh x')).toBe('! bash ~/b.sh x')
  expect(lastBang('```\n!bash ~/c.sh\n```')).toBe('! bash ~/c.sh')
})

test('ignores answers with no bang line', () => {
  expect(lastBang('Done!\nNo command here.')).toBeUndefined()
  expect(lastBang('')).toBeUndefined()
})

test('takes a backticked command inside a bullet or sentence', () => {
  expect(lastBang('- Allow it: run `! bash ~/allow.sh x`, then I continue.')).toBe('! bash ~/allow.sh x')
  expect(lastBang('Rerun `!bash ~/a.sh` and `! bash ~/b.sh` after.')).toBe('! bash ~/b.sh')
})

test('prefers the command on the recommended line', () => {
  const decision = [
    'Decision:',
    '- **Allow it (recommended):** run `! bash ~/allow.sh`, and I apply.',
    '- **Ask Luis:** he runs `! bash ~/other.sh` himself.',
  ].join('\n')
  expect(lastBang(decision)).toBe('! bash ~/allow.sh')
})

test('a bare ! in prose, or a span with no space after !, is not a command', () => {
  expect(lastBang('- Done! It works.')).toBeUndefined()
  expect(lastBang('the `!important` flag and `a != b`')).toBeUndefined()
})

test('takes a one-command shell block, continuations joined', () => {
  expect(lastBang('Run it:\n\n```bash\n~/allow.sh \\\n  \'Bash(a:*)\' \\\n  \'Bash(b:*)\'\n```\n\nThen I continue.'))
    .toBe("! ~/allow.sh 'Bash(a:*)' 'Bash(b:*)'")
  expect(lastBang('```sh\n!bash ~/c.sh\n```')).toBe('! bash ~/c.sh')
})

test('a shell block of several commands, or an unlabelled block, hands over nothing', () => {
  expect(lastBang('```bash\ncd /tmp\nls\n```')).toBeUndefined()
  expect(lastBang('```bash\n# just a comment\n```')).toBeUndefined()
  expect(lastBang('```\nterraform plan\n```')).toBeUndefined()
  expect(lastBang('```json\n{"a": 1}\n```')).toBeUndefined()
})

test('a shell block introduced by the recommended line wins', () => {
  const decision = [
    'Decision:',
    '- **Allow it (recommended):**',
    '```sh',
    '~/allow.sh x',
    '```',
    '- **Ask Luis:** he runs `! bash ~/other.sh` himself.',
  ].join('\n')
  expect(lastBang(decision)).toBe('! ~/allow.sh x')
})

const turn = (answer: string) => ({ answer, reason: 'answer' as const, durationMs: 1, isAborted: false, turnId: 't' })
const guess = { text: 'I typed it', origin: { kind: 'suggestion' as const } }

test('the engine guess does not replace an offered command until the next prompt', async ($, on) => {
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('prompt.suggest', () => ({ isShown: true }))
  on('prompt.submit', ($, e) => ({ text: e.text }))

  await $.turn.complete(turn('Run it:\n\n! echo hi'))
  expect((await $.prompt.suggest(guess)).isShown).toBe(false)

  await $.prompt.submit({ text: 'next' })
  expect((await $.prompt.suggest(guess)).isShown).toBe(true)
})

test('the engine guess shows after an answer with no command', async ($, on) => {
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('prompt.suggest', () => ({ isShown: true }))

  await $.turn.complete(turn('Run it:\n\n! echo hi'))
  await $.turn.complete(turn('Done.'))
  expect((await $.prompt.suggest(guess)).isShown).toBe(true)
})

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

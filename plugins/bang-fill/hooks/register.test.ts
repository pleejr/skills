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

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

const source = readFileSync(new URL('../src/dshManager.ts', import.meta.url), 'utf8')
// Execute the actual production timer block with a fake clock, without loading
// VS Code or spawning a Harness. Fail if the block changes shape (review required).
const timerBlock = source.match(/const startupTimer = setTimeout\(\(\) => \{[\s\S]*?\}, \d+\)/)?.[0]
assert.ok(timerBlock, 'Startup timer must be found in the production manager')

function startupClock(isSettled = false) {
  let now = 0
  let callback
  let deadline
  const errors = []
  const statuses = []
  const logs = []
  runInNewContext(timerBlock, {
    isSettled,
    setTimeout(fn, delay) { callback = fn; deadline = now + delay },
    reject(error) { errors.push(error) },
    outputChannel: { appendLine(line) { logs.push(line) } },
    setStatus(status, info) { statuses.push({ status, info }) },
  })
  return {
    errors, statuses, logs,
    tick(ms) {
      now += ms
      if (callback && now >= deadline) {
        const fn = callback
        callback = undefined
        fn()
      }
    },
  }
}

describe('EveryWhere Harness VS Code Extension - Startup timeout', () => {
  it('allows 30 more seconds beyond the original 35 seconds', () => {
    const clock = startupClock()
    clock.tick(35000)
    assert.equal(clock.errors.length, 0)
    clock.tick(29999)
    assert.equal(clock.errors.length, 0)
    assert.equal(clock.statuses.length, 0)
    clock.tick(1)
    assert.equal(clock.errors.length, 1)
    assert.equal(clock.errors[0].message, 'Timeout waiting for EveryWhere Harness to start. Check output logs for details.')
    assert.equal(clock.statuses[0].status, 'error')
    assert.equal(clock.logs.length, 1)
  })

  it('does not report a timeout once startup has already settled', () => {
    const clock = startupClock(true)
    clock.tick(65000)
    assert.equal(clock.errors.length, 0)
    assert.equal(clock.statuses.length, 0)
    assert.equal(clock.logs.length, 0)
  })
})

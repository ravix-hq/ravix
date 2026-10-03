import {afterEach, beforeEach, expect, setSystemTime, test} from 'bun:test'
import {age, RelativeTime, TICK_MS} from '../js/hooks/relative_time.js'
import {mountHook} from './setup.js'

const start = Date.parse('2026-09-30T12:00:00Z')
const realSetInterval = globalThis.setInterval
const realClearInterval = globalThis.clearInterval
let intervals

beforeEach(() => {
  intervals = new Map()
  let next = 1
  globalThis.setInterval = (fn, ms) => { const id = next++; intervals.set(id, {fn, ms}); return id }
  globalThis.clearInterval = id => intervals.delete(id)
  setSystemTime(new Date(start))
  document.body.innerHTML = ''
})

afterEach(() => {
  globalThis.setInterval = realSetInterval
  globalThis.clearInterval = realClearInterval
  setSystemTime()
})

const tick = ms => {
  setSystemTime(new Date(Date.now() + ms))
  intervals.forEach(({fn}) => fn())
}

// What the server sent: text as of its render, the stable name in data-label.
const row = (id, iso, text) => `
  <a id="tab-${id}" data-label="Track ${id}, created by @fixture" aria-label="Track ${id}, created by @fixture, active stale">
    <span class="track-title">Track ${id}</span>
    <time id="age-${id}" datetime="${iso}" title="Last active (server)">${text}</time>
  </a>`

test('ages update on the client, with no server render between them', () => {
  document.body.innerHTML = row('a', '2026-09-30T11:59:30Z', 'now') + row('b', '2026-09-29T14:00:00Z', '21h')
  const a = mountHook(RelativeTime, '#age-a').hook
  const b = mountHook(RelativeTime, '#age-b').hook
  const text = id => document.getElementById(`age-${id}`).textContent

  // Mounting corrects whatever the server wrote a moment ago.
  expect(text('a')).toBe('now')
  expect(text('b')).toBe('22h')
  expect(document.getElementById('tab-b').getAttribute('aria-label'))
    .toBe('Track b, created by @fixture, active 22 hours ago')
  expect(document.getElementById('age-b').title).toStartWith('Last active ')
  expect(document.getElementById('age-b').title).not.toBe('Last active (server)')

  // Both share one timer, and time passing is all it takes.
  expect(intervals.size).toBe(1)
  expect([...intervals.values()][0].ms).toBe(TICK_MS)
  tick(5 * 60_000)
  expect(text('a')).toBe('5m')
  expect(document.getElementById('tab-a').getAttribute('aria-label'))
    .toBe('Track a, created by @fixture, active 5 minutes ago')
  tick(2 * 3_600_000)
  expect(text('a')).toBe('2h')
  expect(text('b')).toBe('1d')
  expect(document.getElementById('tab-b').getAttribute('aria-label')).toEndWith('active 1 day ago')

  // A patch that brings a newer time is shown at once.
  document.getElementById('age-b').setAttribute('datetime', new Date(Date.now() - 2_000).toISOString())
  b.updated()
  expect(text('b')).toBe('now')

  // The timer outlives one row and stops with the last.
  b.destroyed()
  expect(intervals.size).toBe(1)
  a.destroyed()
  expect(intervals.size).toBe(0)
})

test('a row outside a labelled link and an unreadable time are left alone', () => {
  document.body.innerHTML = `<li><time id="age-c" datetime="2026-09-28T12:00:00Z">?</time></li><time id="age-d" datetime="soon">kept</time>`
  const c = mountHook(RelativeTime, '#age-c').hook
  const d = mountHook(RelativeTime, '#age-d').hook
  expect(document.getElementById('age-c').textContent).toBe('2d')
  expect(document.getElementById('age-d').textContent).toBe('kept')
  c.destroyed()
  d.destroyed()
})

test('ages read the same as the server writes them', () => {
  const now = start
  const cases = [
    [0, 'now', 'just now'],
    [-5_000, 'now', 'just now'],
    [59_000, 'now', 'just now'],
    [60_000, '1m', '1 minute ago'],
    [3_600_000, '1h', '1 hour ago'],
    [22 * 3_600_000, '22h', '22 hours ago'],
    [86_400_000, '1d', '1 day ago'],
    [29 * 86_400_000, '29d', '29 days ago'],
    [30 * 86_400_000, '1mo', '1 month ago'],
    [400 * 86_400_000, '1y', '1 year ago'],
  ]
  for (const [ms, short, words] of cases) expect(age(now - ms, now)).toEqual({short, words})
})

test('the Inbox\'s "ago" style says so in words, with its own tooltip prefix', () => {
  document.body.innerHTML = `
    <time id="ago-a" data-style="ago" data-title-prefix="" datetime="2026-09-30T10:00:00Z">2h ago</time>
    <time id="ago-b" data-style="ago" data-title-prefix="" datetime="2026-09-30T11:59:50Z">now</time>`
  mountHook(RelativeTime, '#ago-a')
  mountHook(RelativeTime, '#ago-b')
  expect(document.getElementById('ago-a').textContent).toBe('2h ago')
  expect(document.getElementById('ago-a').title).toContain('2026')
  expect(document.getElementById('ago-a').title).not.toStartWith('Last active')
  expect(document.getElementById('ago-b').textContent).toBe('just now')
})

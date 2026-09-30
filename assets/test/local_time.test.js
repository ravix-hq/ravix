import {afterEach, beforeEach, expect, setSystemTime, test} from 'bun:test'
import {fullTime, localTime, LocalTime} from '../js/hooks/local_time.js'
import {mountHook} from './setup.js'

// 12:00 UTC is 08:00 in New York and 17:30 in Kolkata, the same day.
const now = Date.parse('2026-09-30T12:00:00Z')
const realZone = process.env.TZ

beforeEach(() => {
  setSystemTime(new Date(now))
  document.body.innerHTML = ''
})

afterEach(() => {
  setSystemTime()
  process.env.TZ = realZone
})

const en = {now, locale: 'en-US'}

test('today is the time alone, older is the date and the time', () => {
  expect(localTime(Date.parse('2026-09-30T16:15:00Z'), {...en, timeZone: 'America/New_York'})).toBe('12:15 PM')
  expect(localTime(Date.parse('2026-09-28T20:27:00Z'), {...en, timeZone: 'America/New_York'})).toBe('Sep 28, 4:27 PM')
})

test('another year says which', () => {
  expect(localTime(Date.parse('2025-12-31T20:00:00Z'), {...en, timeZone: 'America/New_York'}))
    .toBe('Dec 31, 2025, 3:00 PM')
})

test('"today" is the viewer\'s day, not the UTC one', () => {
  // 02:30 UTC on the 30th is still the evening of the 29th in New York...
  const late = Date.parse('2026-09-30T02:30:00Z')
  expect(localTime(late, {...en, timeZone: 'America/New_York'})).toBe('Sep 29, 10:30 PM')
  // ...and already the morning of the 30th in Kolkata.
  expect(localTime(late, {...en, timeZone: 'Asia/Kolkata'})).toBe('8:00 AM')
})

test('the locale decides between 12 and 24 hours', () => {
  expect(localTime(Date.parse('2026-09-30T16:15:00Z'), {now, locale: 'en-GB', timeZone: 'Europe/London'})).toBe('17:15')
})

test('the full form names the zone', () => {
  expect(fullTime(Date.parse('2026-09-28T20:27:00Z'), {locale: 'en-US', timeZone: 'America/New_York'}))
    .toBe('Mon, Sep 28, 2026, 4:27 PM Eastern Daylight Time')
})

test('the hook rewrites the server fallback in the browser\'s zone, with a title', () => {
  process.env.TZ = 'America/New_York'
  document.body.innerHTML = `
    <time id="t-today" datetime="2026-09-30T16:15:00Z" title="server">4:15 PM</time>
    <time id="t-old" datetime="2026-09-28T20:27:00Z" data-title-prefix="Ended " title="server">Sep 28, 8:27 PM</time>`
  mountHook(LocalTime, '#t-today')
  const old = mountHook(LocalTime, '#t-old').hook
  const today = document.getElementById('t-today')
  const older = document.getElementById('t-old')

  expect(today.textContent).toBe(localTime(Date.parse('2026-09-30T16:15:00Z')))
  expect(today.textContent).toMatch(/^12:15\s?(PM)?$/)
  expect(today.title).toContain('2026')
  expect(today.title).toContain(fullTime(Date.parse('2026-09-30T16:15:00Z')))
  expect(older.textContent).toMatch(/^Sep 28, 4:27/)
  expect(older.title).toStartWith('Ended ')
  expect(older.title).not.toContain('UTC')

  // A patch that moved the time is written again.
  older.setAttribute('datetime', '2026-09-30T13:05:00Z')
  old.updated()
  expect(older.textContent).toMatch(/^9:05/)
})

// RAV-93: a turn's footer names the last six days by weekday.
test('with weekday, the six days before today are named by weekday', () => {
  const ny = {...en, timeZone: 'America/New_York', weekday: true}
  // Wednesday the 30th, 08:00 in New York.
  expect(localTime(Date.parse('2026-09-30T13:05:00Z'), ny)).toBe('9:05 AM')
  expect(localTime(Date.parse('2026-09-27T01:49:00Z'), ny)).toBe('Sat 9:49 PM')
  expect(localTime(Date.parse('2026-09-29T20:00:00Z'), ny)).toBe('Tue 4:00 PM')
  expect(localTime(Date.parse('2026-09-24T16:00:00Z'), ny)).toBe('Thu 12:00 PM')
  // Seven days back is a date again, so "Wed" never means two days.
  expect(localTime(Date.parse('2026-09-23T16:00:00Z'), ny)).toBe('Sep 23, 12:00 PM')
  // Without the option nothing changes.
  expect(localTime(Date.parse('2026-09-27T01:49:00Z'), {...en, timeZone: 'America/New_York'})).toBe('Sep 26, 9:49 PM')
})

test('the hook uses the weekday form when the element asks for it', () => {
  process.env.TZ = 'America/New_York'
  document.body.innerHTML = '<time id="t-week" datetime="2026-09-27T01:49:00Z" data-weekday>Sep 27, 1:49 AM</time>'
  mountHook(LocalTime, '#t-week')
  expect(document.getElementById('t-week').textContent).toMatch(/^Sat 9:49/)
})

test('an unparseable datetime keeps what the server wrote', () => {
  document.body.innerHTML = '<time id="bad" datetime="soon" title="server">soon</time>'
  mountHook(LocalTime, '#bad')
  expect(document.getElementById('bad').textContent).toBe('soon')
  expect(document.getElementById('bad').title).toBe('server')
})

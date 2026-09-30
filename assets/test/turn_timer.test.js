import {afterEach, beforeEach, expect, jest, test} from "bun:test"
import {TurnTimer, formatDuration} from "../js/hooks/turn_timer.js"
import {mountHook} from "./setup.js"

// Fake timers must be restored before setup.js tears happy-dom down. Times
// are relative to the fake clock's start: Bun's `advanceTimersByTime` does
// not keep a `setSystemTime`.
let now
beforeEach(() => {
  jest.useFakeTimers()
  now = Date.now()
})
afterEach(() => jest.useRealTimers())

const iso = ms => new Date(ms).toISOString()

// The server rendered 6.7 seconds into the turn unless told otherwise.
function render({started = now - 6700, server = now} = {}) {
  document.body.innerHTML =
    `<span id="timer" data-started="${iso(started)}" data-now="${iso(server)}">6s</span>`
  return mountHook(TurnTimer, "#timer")
}

test("formats as the server's duration/1 does", () => {
  expect(formatDuration(-3)).toBe("0s")
  expect(formatDuration(6.7)).toBe("6s")
  expect(formatDuration(59.99)).toBe("59s")
  expect(formatDuration(60)).toBe("1m 0s")
  expect(formatDuration(125)).toBe("2m 5s")
  expect(formatDuration(3599)).toBe("59m 59s")
  expect(formatDuration(3600)).toBe("1h 0m")
  expect(formatDuration(4 * 3600 + 61)).toBe("4h 1m")
})

test("ticks on each whole second on the client and never pushes an event", () => {
  const {hook, events} = render()
  expect(hook.el.textContent).toBe("6s")
  jest.advanceTimersByTime(299)
  expect(hook.el.textContent).toBe("6s")
  jest.advanceTimersByTime(1)
  expect(hook.el.textContent).toBe("7s")
  jest.advanceTimersByTime(3900)
  expect(hook.el.textContent).toBe("10s")
  jest.advanceTimersByTime(55_000)
  expect(hook.el.textContent).toBe("1m 5s")
  expect(events).toEqual([])
})

test("a reload mid-turn resumes from the real start, not zero", () => {
  const {hook} = render({started: now - 13 * 60_000 - 400})
  expect(hook.el.textContent).toBe("13m 0s")
})

test("counts on the server's clock when the browser's is off", () => {
  // The browser runs 90 seconds fast: the server's `now` is behind it.
  const {hook} = render({started: now - 90_000 - 6700, server: now - 90_000})
  expect(hook.el.textContent).toBe("6s")
  jest.advanceTimersByTime(1300)
  expect(hook.el.textContent).toBe("8s")
})

test("a missing server clock falls back to the browser's", () => {
  document.body.innerHTML = `<span id="timer" data-started="${iso(now - 2500)}">2s</span>`
  const {hook} = mountHook(TurnTimer, "#timer")
  expect(hook.el.textContent).toBe("2s")
})

test("a patch resyncs to the server's reading and keeps a single clock", () => {
  const {hook} = render()
  jest.advanceTimersByTime(2000)
  hook.el.textContent = "8s"
  hook.el.dataset.now = iso(Date.now())
  hook.updated()
  expect(hook.el.textContent).toBe("8s")
  jest.advanceTimersByTime(1000)
  expect(hook.el.textContent).toBe("9s")
  expect(jest.getTimerCount()).toBe(1)
})

test("settling removes the element and stops the clock", () => {
  const {hook} = render()
  hook.destroyed()
  hook.el.textContent = "16s"
  jest.advanceTimersByTime(5000)
  expect(hook.el.textContent).toBe("16s")
  expect(jest.getTimerCount()).toBe(0)
})

test("an unreadable start leaves the server's text alone", () => {
  document.body.innerHTML = `<span id="timer" data-started="soon">6s</span>`
  const {hook} = mountHook(TurnTimer, "#timer")
  jest.advanceTimersByTime(5000)
  expect(hook.el.textContent).toBe("6s")
})

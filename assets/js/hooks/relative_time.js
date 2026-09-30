// A `<time datetime>` that says how long ago it was ("now", "5m", "22h",
// "2d") and keeps saying it while the page stays open. The server renders
// the same text once; ageing it is the browser's job, because a server tick
// per row per minute would re-render the rail for every viewer to move one
// word. Every mounted element shares one timer.
//
// The absolute time goes in the element's `title`, in this browser's time
// zone. An ancestor with `data-label` is a link whose accessible name hides
// the text, so its `aria-label` is that label plus the age in words.

import {fullTime} from './local_time.js'

const MINUTE = 60, HOUR = 60 * MINUTE, DAY = 24 * HOUR, MONTH = 30 * DAY, YEAR = 365 * DAY
export const TICK_MS = 30_000

const units = [[YEAR, 'y', 'year'], [MONTH, 'mo', 'month'], [DAY, 'd', 'day'], [HOUR, 'h', 'hour'], [MINUTE, 'm', 'minute']]

// Mirrors `RavixWeb.WorkspaceLive`'s server-side rendering of the same age.
export function age(then, now = Date.now()) {
  const seconds = Math.max(0, Math.floor((now - then) / 1000))
  for (const [size, short, word] of units) {
    if (seconds >= size) {
      const n = Math.floor(seconds / size)
      return {short: `${n}${short}`, words: `${n} ${word}${n === 1 ? '' : 's'} ago`}
    }
  }
  return {short: 'now', words: 'just now'}
}

const mounted = new Set()
let timer = null

// `data-style="ago"` writes "2h ago" rather than the rail's bare "2h", for
// a place with room for the words; `data-title-prefix` replaces the
// tooltip's "Last active ".
function text(el, short) {
  if (el.dataset.style !== 'ago') return short
  return short === 'now' ? 'just now' : `${short} ago`
}

function render(el, now = Date.now()) {
  const then = Date.parse(el.getAttribute('datetime'))
  if (Number.isNaN(then)) return
  const {short, words} = age(then, now)
  const shown = text(el, short)
  if (el.textContent !== shown) el.textContent = shown
  el.title = `${el.dataset.titlePrefix ?? 'Last active '}${fullTime(then)}`
  const link = el.closest('[data-label]')
  if (link) link.setAttribute('aria-label', `${link.dataset.label}, active ${words}`)
}

function tick() {
  const now = Date.now()
  mounted.forEach(el => render(el, now))
}

export const RelativeTime = {
  mounted() {
    mounted.add(this.el)
    render(this.el)
    if (timer === null) timer = setInterval(tick, TICK_MS)
  },
  updated() { render(this.el) },
  destroyed() {
    mounted.delete(this.el)
    if (mounted.size === 0 && timer !== null) {
      clearInterval(timer)
      timer = null
    }
  },
}

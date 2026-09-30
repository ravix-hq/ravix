// A running turn's elapsed time, ticking in the browser. The server renders
// the turn's start as `data-started` and its own clock as `data-now`; the
// difference between `data-now` and this browser's clock at render is the
// skew, so a reload mid-turn resumes from the real start and a fast or slow
// laptop clock does not shift it. Nothing is pushed: a tick is presentation,
// and the server replaces this element with the final duration on settling.
// Formatted as `RavixWeb.TrackLive.running_duration/1` formats it: tenths
// of a second for the first minute ("3.7s", RAV-93), then as the settled
// footer's `duration/1` does. The tooltip's start time is the viewer's own,
// as `LocalTime` writes it.
import {fullTime} from './local_time.js'

export function formatDuration(seconds) {
  // Through whole milliseconds, so 4.1 * 10 is never read as 40.99….
  const tenths = Math.max(Math.floor(Math.round(seconds * 1000) / 100), 0)
  if (tenths < 600) return `${Math.floor(tenths / 10)}.${tenths % 10}s`
  const s = Math.floor(tenths / 10)
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
}

export const TurnTimer = {
  mounted() {
    this.sync()
  },
  // A patch rewrites the text with the server's own reading and may carry a
  // new `data-now`; take both, then keep ticking from there.
  updated() {
    this.sync()
  },
  destroyed() {
    this.stop()
  },
  // The generation retires a tick already queued, whatever the timer API
  // does with the handle.
  stop() {
    this.generation = (this.generation ?? 0) + 1
    clearTimeout(this.timer)
  },
  sync() {
    this.stop()
    this.started = Date.parse(this.el.dataset.started)
    const now = Date.parse(this.el.dataset.now)
    this.skew = Number.isNaN(now) ? 0 : now - Date.now()
    if (Number.isNaN(this.started)) return
    this.el.title = `Running since ${fullTime(this.started)}`
    this.tick(this.generation)
  },
  // Wake on the next step of what is shown, a tenth for the first minute and
  // a second after it, rather than every step from mount, so the shown value
  // never lags the true one by most of a step.
  tick(generation) {
    if (generation !== this.generation) return
    const elapsed = Date.now() + this.skew - this.started
    this.el.textContent = formatDuration(elapsed / 1000)
    const step = elapsed < 60_000 ? 100 : 1000
    this.timer = setTimeout(() => this.tick(generation), step - (((elapsed % step) + step) % step))
  },
}

// A running turn's elapsed time, ticking in the browser. The server renders
// the turn's start as `data-started` and its own clock as `data-now`; the
// difference between `data-now` and this browser's clock at render is the
// skew, so a reload mid-turn resumes from the real start and a fast or slow
// laptop clock does not shift it. Nothing is pushed: a tick is presentation,
// and the server replaces this element with the final duration on settling.
// Formatted as `RavixWeb.TrackLive.duration/1` formats it.
export function formatDuration(seconds) {
  const s = Math.max(Math.floor(seconds), 0)
  if (s < 60) return `${s}s`
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
    this.tick(this.generation)
  },
  // Wake on the next whole second of elapsed time rather than every 1000ms
  // from mount, so the shown value never lags the true one by most of a second.
  tick(generation) {
    if (generation !== this.generation) return
    const elapsed = Date.now() + this.skew - this.started
    this.el.textContent = formatDuration(elapsed / 1000)
    this.timer = setTimeout(() => this.tick(generation), 1000 - (((elapsed % 1000) + 1000) % 1000))
  },
}

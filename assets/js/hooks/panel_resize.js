// The drag handle between two panels.
//
// A captured pointer keeps resizing when it leaves the narrow divider, and
// the width it sets is a CSS custom property on `<html>` that the grid
// template reads, so the layout is still the stylesheet's decision. Pure
// client: a panel width is a preference of this browser, saved in
// localStorage, and the server never hears about it. What the hook expects:
//
//   <div phx-hook="PanelResize" id="yard-resize"
//        class="panel-resize-handle left" role="separator" tabindex="0"
//        aria-label="Sidebar width" aria-orientation="vertical"
//        data-axis="x" data-var="--yard-width" data-min="220" data-max="480"
//        data-key="ravix.panel-width.left" data-side="left"></div>
//
//   data-var    the custom property to set, in px
//   data-min    the smallest width allowed
//   data-max    the largest, before the space actually available is considered
//   data-key    where the width is remembered
//   data-side   `left` when dragging right makes the panel wider, `right` when
//               it makes it narrower (the inspector hangs off the right edge)
//   data-axis   `x`; kept for a future horizontal divider
//
// The handle sits inside the panel it resizes, which is how it measures the
// panel's current width; the grid it lives in is the nearest `.app`.

const RESERVE_WIDE = 700
const RESERVE_NARROW = 420

export const PanelResize = {
  mounted() {
    this.side = this.el.dataset.side || "left"
    this.property = this.el.dataset.var
    this.key = this.el.dataset.key
    this.minimum = Number(this.el.dataset.min) || 0
    this.ceiling = Number(this.el.dataset.max) || 800
    this.maximum = this.ceiling
    this.width = 0
    this.drag = null

    const saved = this.saved()
    if (saved !== null) this.set(Math.min(this.ceiling, saved))

    this.measure = () => {
      const app = this.app()
      const panel = this.panel()
      const available =
        this.side === "left"
          ? app.clientWidth - (window.innerWidth > 1100 ? RESERVE_WIDE : RESERVE_NARROW)
          : panel.parentElement.clientWidth - RESERVE_NARROW
      this.maximum = Math.max(this.minimum, Math.min(this.ceiling, available))
      this.width = Math.round(panel.getBoundingClientRect().width)
      this.reflect()
    }
    this.measure()
    this.observer = new ResizeObserver(this.measure)
    this.observer.observe(this.app())
    this.observer.observe(this.panel())

    this.el.addEventListener("pointerdown", e => {
      if (e.button !== 0 || !e.isPrimary) return
      e.preventDefault()
      this.el.focus()
      this.el.setPointerCapture(e.pointerId)
      this.drag = {x: e.clientX, width: this.width, pointer: e.pointerId}
      this.el.dataset.dragging = "true"
    })
    this.el.addEventListener("pointermove", e => {
      const start = this.drag
      if (!start || start.pointer !== e.pointerId) return
      this.resize(start.width + (e.clientX - start.x) * this.direction())
    })
    this.el.addEventListener("pointerup", e => {
      if (this.drag?.pointer !== e.pointerId) return
      this.el.releasePointerCapture(e.pointerId)
      this.stop()
    })
    this.el.addEventListener("pointercancel", () => this.stop())
    this.el.addEventListener("lostpointercapture", () => this.stop())
    this.el.addEventListener("keydown", e => {
      const step = e.shiftKey ? 50 : 10
      if (e.key === "ArrowLeft") this.resize(this.width - step * this.direction())
      else if (e.key === "ArrowRight") this.resize(this.width + step * this.direction())
      else if (e.key === "Home") this.resize(this.minimum)
      else if (e.key === "End") this.resize(this.maximum)
      else return
      e.preventDefault()
    })
  },

  updated() {
    this.reflect()
  },

  destroyed() {
    this.observer?.disconnect()
  },

  direction() {
    return this.side === "left" ? 1 : -1
  },

  app() {
    return this.el.closest(".app") || document.documentElement
  },

  panel() {
    return (this.side === "left" && this.app().querySelector(".yard")) || this.el.parentElement
  },

  stop() {
    this.drag = null
    this.el.dataset.dragging = "false"
  },

  saved() {
    try {
      const value = Number(localStorage.getItem(this.key))
      return Number.isFinite(value) && value >= this.minimum && value > 0 ? value : null
    } catch {
      // Resizing still works without storage.
      return null
    }
  },

  set(value) {
    document.documentElement.style.setProperty(this.property, `${value}px`)
  },

  resize(value) {
    const next = Math.round(Math.max(this.minimum, Math.min(this.maximum, value)))
    this.set(next)
    this.width = next
    this.reflect()
    try {
      localStorage.setItem(this.key, String(next))
    } catch {
      // Storage may be disabled.
    }
  },

  reflect() {
    this.el.setAttribute("aria-valuemin", String(this.minimum))
    this.el.setAttribute("aria-valuemax", String(this.maximum))
    this.el.setAttribute("aria-valuenow", String(this.width))
    if (!this.el.dataset.dragging) this.el.dataset.dragging = "false"
  },
}

// Whether a sidebar is open.
//
// Its width is already a preference of this browser (see PanelResize): the
// server never hears about it, and the layout stays a decision the
// stylesheet makes. Open or closed is the same kind of fact. The button
// writes one attribute on `<html>` — `data-yard` or `data-inspector` — and
// `app.css` is what collapses that side to the rail the button sits on.
//
// The saved value lives in localStorage. `priv/static/theme.js` reads the
// same keys before the first paint, so a sidebar that was closed does not
// flash open while LiveView connects. Two places holding one string is a
// thing that rots; `components_test.exs` asserts they still agree.
//
//   <button phx-hook="PanelToggle" id="yard-toggle" type="button"
//           data-panel="yard" data-key="ravix.panel.yard"
//           data-hide-label="Hide projects" data-show-label="Show projects"
//           data-tip="Hide projects" data-tip-kbd="⌘B"
//           aria-controls="yard" aria-expanded="true">
//
//   data-panel       `yard` or `inspector`: the attribute set on `<html>`
//   data-hide-label  the tooltip while that sidebar is open
//   data-show-label  the tooltip while it is closed
//   data-shortcut    optional: a letter that, with Ctrl or ⌘, clicks the
//                    button while it is on screen (the yard's is B, RAV-96)
//
// The accessible name is the visually hidden label the stylesheet swaps.
// This hook only has to keep the tooltip and `aria-expanded` honest after
// a click, and again after a server patch resets them to the open state
// the template was written in.

export const YARD_KEY = "ravix.panel.yard"
export const INSPECTOR_KEY = "ravix.panel.inspector"

const KEYS = {yard: YARD_KEY, inspector: INSPECTOR_KEY}

export const PanelToggle = {
  mounted() {
    this.panel = this.el.dataset.panel
    this.key = KEYS[this.panel]
    if (!this.key) return

    this.sync(this.stored())
    this.el.addEventListener("click", () => {
      const closed = !this.closed()
      this.sync(closed)
      this.remember(closed)
    })
    const letter = this.el.dataset.shortcut
    if (!letter) return
    this.onKey = event => {
      if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey || event.repeat) return
      if (event.defaultPrevented || event.key.toLowerCase() !== letter) return
      // A phone's drawer has its own Menu button; the toggle is not drawn.
      if (this.el.getClientRects().length === 0) return
      event.preventDefault()
      this.el.click()
    }
    window.addEventListener("keydown", this.onKey)
  },

  destroyed() {
    if (this.onKey) window.removeEventListener("keydown", this.onKey)
  },

  updated() {
    if (this.key) this.reflect()
  },

  closed() {
    return document.documentElement.dataset[this.panel] === "closed"
  },

  stored() {
    try {
      return localStorage.getItem(this.key) === "closed"
    } catch {
      // Site data switched off. Both sidebars stay as they are on the page.
      return false
    }
  },

  remember(closed) {
    try {
      localStorage.setItem(this.key, closed ? "closed" : "open")
    } catch {
      // This visit still toggles. The next one opens both sidebars.
    }
  },

  sync(closed) {
    this.paint(closed)
    this.reflect()
  },

  paint(closed) {
    if (closed) document.documentElement.dataset[this.panel] = "closed"
    else delete document.documentElement.dataset[this.panel]
  },

  reflect() {
    const closed = this.closed()
    this.el.setAttribute("aria-expanded", closed ? "false" : "true")
    this.el.dataset.tip = closed ? this.el.dataset.showLabel : this.el.dataset.hideLabel
  },
}

// The Share popover (RAV-84) hangs under the Share button rather than in a
// scrim. Where the button is is the browser's to measure, so this hook puts
// the panel below it, right edges aligned and kept inside the viewport, and
// again whenever the page resizes or scrolls. Below NARROW the stylesheet
// shows it as the centred dialog it used to be, and the hook stays out of
// the way.
//
// A second click on Share closes it. That click is outside the panel, so
// left alone it would close it (`phx-click-away`) and open it again (the
// button's own `phx-click`); the hook takes it first and presses Close,
// which closes exactly as Escape does. `C` anywhere in the panel but a text
// field presses Copy link.

export const NARROW = 640
export const GAP = 6
export const MARGIN = 8

export function place(anchor, panel, viewport) {
  const a = anchor.getBoundingClientRect()
  const width = panel.offsetWidth
  const left = Math.min(Math.max(a.right - width, MARGIN), Math.max(viewport.width - width - MARGIN, MARGIN))
  return {top: Math.round(a.bottom + GAP), left: Math.round(left)}
}

const typing = el => el.closest?.("input, textarea, select, [contenteditable='true']")

export const SharePopover = {
  mounted() {
    this.anchor = () => document.getElementById(this.el.dataset.anchor)
    this.position = () => this.place()
    this.toggle = e => {
      if (this.el.hidden) return
      e.preventDefault()
      e.stopPropagation()
      this.el.querySelector(".dialog-head .x")?.click()
    }
    this.key = e => {
      if (e.key !== "c" && e.key !== "C") return
      if (e.metaKey || e.ctrlKey || e.altKey || e.isComposing || typing(e.target)) return
      const copy = this.el.querySelector("#share-link button")
      if (!copy) return
      e.preventDefault()
      copy.click()
    }
    this.boundAnchor = this.anchor()
    this.boundAnchor?.addEventListener("click", this.toggle, true)
    this.el.addEventListener("keydown", this.key)
    window.addEventListener("resize", this.position)
    window.addEventListener("scroll", this.position, true)
    this.place()
  },
  // The body grows as people are added and removed; its width does not,
  // but a new render can land after the header moved.
  updated() {
    this.place()
  },
  destroyed() {
    this.boundAnchor?.removeEventListener("click", this.toggle, true)
    window.removeEventListener("resize", this.position)
    window.removeEventListener("scroll", this.position, true)
  },
  place() {
    const anchor = this.anchor()
    const panel = this.el.firstElementChild
    if (!anchor || !panel || window.innerWidth < NARROW) {
      this.el.style.removeProperty("top")
      this.el.style.removeProperty("left")
      this.el.removeAttribute("data-placed")
      return
    }
    const {top, left} = place(anchor, panel, {width: window.innerWidth})
    this.el.style.top = `${top}px`
    this.el.style.left = `${left}px`
    this.el.setAttribute("data-placed", "")
  },
}

// The app's one tooltip (RAV-98).
//
// Any element with `data-tip` gets it: after a short pause under the
// pointer, or at once when the keyboard focuses it. `data-tip-kbd` adds the
// shortcut beside the text ("Search  ⌘K"). `<.icon_button>` writes both,
// and `scripts/icon_labels.mjs` fails the build on an icon-only control
// without one, so the native `title` (mouse only, slow, and unstyled) is not
// used for controls.
//
// There is one element, `#tooltip`, made the first time it is needed. It is
// a manual popover so it is drawn in the top layer, over menus and dialogs,
// and never clipped by a scroller; it is `aria-hidden` because what it says
// is already the control's accessible name and `aria-keyshortcuts`. It sits
// under the control, or over it when there is no room below, kept inside
// the viewport. A press, Escape, a scroll or the control leaving the page
// hides it; it does not come back until the pointer or focus moves on.

export const HOVER_DELAY_MS = 450
// Moving from one tipped control to the next shows the next at once.
export const WARM_MS = 600
const GAP = 6
const MARGIN = 4

export function installTooltips(win = window) {
  const doc = win.document
  let tip = null
  let anchor = null
  let timer = null
  let warmUntil = 0
  let dismissed = null

  const element = () => {
    if (tip && tip.isConnected) return tip
    tip = doc.createElement("div")
    tip.id = "tooltip"
    tip.className = "tooltip"
    tip.setAttribute("role", "tooltip")
    tip.setAttribute("aria-hidden", "true")
    tip.setAttribute("popover", "manual")
    doc.body.appendChild(tip)
    return tip
  }

  const target = node => (node instanceof win.Element ? node.closest("[data-tip]") : null)

  const show = el => {
    clearTimeout(timer)
    const text = el.dataset.tip
    if (!text || !el.isConnected) return hide()
    const t = element()
    t.replaceChildren(doc.createTextNode(text))
    if (el.dataset.tipKbd) {
      const kbd = doc.createElement("kbd")
      kbd.textContent = el.dataset.tipKbd
      t.appendChild(kbd)
    }
    anchor = el
    t.hidden = false
    if (t.showPopover && !t.matches(":popover-open")) t.showPopover()
    place(t, el, win)
  }

  const hide = () => {
    clearTimeout(timer)
    if (anchor) warmUntil = Date.now() + WARM_MS
    anchor = null
    if (!tip) return
    if (tip.hidePopover && tip.matches(":popover-open")) tip.hidePopover()
    tip.hidden = true
  }

  const soon = el => {
    clearTimeout(timer)
    if (Date.now() < warmUntil) return show(el)
    timer = setTimeout(() => show(el), HOVER_DELAY_MS)
  }

  const over = e => {
    const el = target(e.target)
    if (el === anchor) return
    if (!el) return hide()
    if (el === dismissed) return
    if (anchor) { hide(); return show(el) }
    soon(el)
  }

  const out = e => {
    const el = target(e.target)
    if (!el) return
    // Still inside the same control: its icon to its padding, say.
    if (e.relatedTarget && el.contains(e.relatedTarget)) return
    if (el === dismissed) dismissed = null
    if (el === anchor || !anchor) hide()
  }

  const focusIn = e => {
    const el = target(e.target)
    if (!el || el === dismissed) return
    // Only keyboard focus: a click already focused it under the pointer.
    if (!focusVisible(el)) return
    show(el)
  }

  const focusOut = e => {
    const el = target(e.target)
    if (el === dismissed) dismissed = null
    if (el && el === anchor) hide()
  }

  const dismiss = () => {
    if (!anchor && !timer) return
    dismissed = anchor || dismissed
    hide()
  }

  const press = e => {
    const el = target(e.target)
    if (el) dismissed = el
    hide()
  }

  const key = e => {
    if (e.key === "Escape" && anchor) dismiss()
  }

  // A patch that removes the control, or rewrites its tip, is followed.
  const observer = new win.MutationObserver(() => {
    if (!anchor) return
    if (!anchor.isConnected || !anchor.dataset.tip) hide()
    else if (tip && tip.firstChild?.textContent !== anchor.dataset.tip) show(anchor)
  })
  observer.observe(doc.body, {subtree: true, childList: true, attributes: true, attributeFilter: ["data-tip"]})

  const listeners = [
    ["mouseover", over],
    ["mouseout", out],
    ["focusin", focusIn],
    ["focusout", focusOut],
    ["pointerdown", press],
    ["keydown", key],
  ]
  for (const [name, fn] of listeners) doc.addEventListener(name, fn, true)
  win.addEventListener("scroll", hide, true)
  win.addEventListener("resize", hide)

  return {
    stop() {
      hide()
      observer.disconnect()
      for (const [name, fn] of listeners) doc.removeEventListener(name, fn, true)
      win.removeEventListener("scroll", hide, true)
      win.removeEventListener("resize", hide)
      tip?.remove()
    },
  }
}

function focusVisible(el) {
  try {
    return el.matches(":focus-visible")
  } catch {
    // A browser without the selector: every focus is shown.
    return true
  }
}

// Under the control and centred on it, or over it when there is no room
// below; always inside the viewport.
export function place(tip, anchor, win = window) {
  const a = anchor.getBoundingClientRect()
  const t = tip.getBoundingClientRect()
  const vw = win.innerWidth
  const vh = win.innerHeight
  let top = a.bottom + GAP
  let side = "below"
  if (top + t.height > vh - MARGIN && a.top - GAP - t.height >= MARGIN) {
    top = a.top - GAP - t.height
    side = "above"
  }
  const centre = a.left + a.width / 2 - t.width / 2
  const left = Math.max(MARGIN, Math.min(centre, vw - MARGIN - t.width))
  tip.style.top = `${Math.round(top)}px`
  tip.style.left = `${Math.round(left)}px`
  tip.dataset.side = side
}

// The app's one tooltip (RAV-98).
//
// Any element with `data-tip` gets it: after a short pause under the
// pointer, or at once when the keyboard focuses it. `data-tip-kbd` adds the
// shortcut beside the text; `Mod+` in it is ⌘ on a Mac and Ctrl+ elsewhere
// ("Mod+K" reads ⌘K or Ctrl+K), so a template names a shortcut once for
// every platform. `<.icon_button>` writes both, and
// `test/ravix_web/icon_labels_test.exs` fails on an icon-only control
// without one, so the native `title` (mouse only, slow, unstyled, and
// without the shortcut) is not used for controls.
//
// There is one element, `#tooltip`, made the first time it is needed. It is
// a manual popover so it is drawn in the top layer, over menus and dialogs,
// and never clipped by a scroller. While it shows, the control is
// `aria-describedby` it, unless it would only repeat the control's name.
// It sits under the control, or over it when there is no room below, kept
// inside the viewport. A press, Escape, a scroll or the control leaving
// the page hides it; it does not come back until the pointer or focus
// moves on.
import {macPlatform} from "./platform"

export const HOVER_DELAY_MS = 300
// Moving from one tipped control to the next shows the next at once.
export const WARM_MS = 600
export const TIP_ID = "tooltip"
const GAP = 6
const MARGIN = 4

/** A `data-tip-kbd` for this platform: `Mod+K` is ⌘K on a Mac, Ctrl+K elsewhere. */
export function keysLabel(keys, mac = macPlatform()) {
  return keys.replace(/\bMod\+/g, mac ? "⌘" : "Ctrl+")
}

export function installTooltips(win = window, {mac = macPlatform(win.navigator)} = {}) {
  const doc = win.document
  let tip = null
  let anchor = null
  let timer = null
  let warmUntil = 0
  let dismissed = null

  const element = () => {
    if (tip && tip.isConnected) return tip
    tip = doc.createElement("div")
    tip.id = TIP_ID
    tip.className = "tooltip"
    tip.setAttribute("role", "tooltip")
    tip.setAttribute("popover", "manual")
    tip.hidden = true
    doc.body.appendChild(tip)
    return tip
  }

  const target = node => (node instanceof win.Element ? node.closest("[data-tip]") : null)

  const describe = (el, on) => {
    const ids = (el.getAttribute("aria-describedby") || "").split(/\s+/).filter(id => id && id !== TIP_ID)
    if (on) ids.push(TIP_ID)
    if (ids.length) el.setAttribute("aria-describedby", ids.join(" "))
    else el.removeAttribute("aria-describedby")
  }

  const show = el => {
    clearTimeout(timer)
    timer = null
    const text = el.dataset.tip
    if (!text || !el.isConnected) return hide()
    if (anchor && anchor !== el) describe(anchor, false)
    const t = element()
    t.replaceChildren(doc.createTextNode(text))
    const keys = el.dataset.tipKbd
    if (keys) {
      const kbd = doc.createElement("kbd")
      kbd.textContent = keysLabel(keys, mac)
      t.appendChild(kbd)
    }
    anchor = el
    // A tip that only repeats the name would be read twice.
    describe(el, Boolean(keys) || text !== el.getAttribute("aria-label"))
    t.hidden = false
    if (t.showPopover && !t.matches(":popover-open")) t.showPopover()
    place(t, el, win)
  }

  const hide = () => {
    clearTimeout(timer)
    timer = null
    if (anchor) {
      warmUntil = Date.now() + WARM_MS
      describe(anchor, false)
    }
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
    if (anchor) return show(el)
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
    // Only keyboard focus: a click, or focus handed back after a dialog a
    // pointer closed, draws no ring and shows no tip (see focus_ring.js).
    if (doc.documentElement.dataset.input === "pointer" || !focusVisible(el)) return
    show(el)
  }

  const focusOut = e => {
    const el = target(e.target)
    if (el === dismissed) dismissed = null
    if (el && el === anchor) hide()
  }

  const press = e => {
    const el = target(e.target)
    if (el) dismissed = el
    hide()
  }

  const key = e => {
    if (e.key !== "Escape" || !anchor) return
    dismissed = anchor
    hide()
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

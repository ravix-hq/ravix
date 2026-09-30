// Whether the last input was a pointer or the keyboard (RAV-98).
//
// The focus ring is `:focus-visible`'s, and browsers already leave it off
// a clicked button. They draw it, though, on focus that script moves: the
// trigger a closing dialog hands focus back to (LiveView's `pop_focus`),
// after a mouse user opened the dialog and pressed Escape or clicked its x.
// So `<html data-input>` says which came last, and `app.css` hides the
// ring while it is `pointer`. Only the keys that move focus or act on it
// make it `keyboard`: typing into a field, or Escape to close something,
// is not navigating by keyboard.

const NAVIGATION = new Set([
  "Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
  "Home", "End", "PageUp", "PageDown", "Enter", " ", "F6",
])

export function trackInputModality(win = window) {
  const root = win.document.documentElement
  const pointer = () => { root.dataset.input = "pointer" }
  const key = e => {
    if (!NAVIGATION.has(e.key) || e.metaKey || e.ctrlKey || e.altKey) return
    // Enter and Space in a text field type; they do not navigate.
    if ((e.key === "Enter" || e.key === " ") && typing(e.target)) return
    root.dataset.input = "keyboard"
  }
  win.addEventListener("pointerdown", pointer, true)
  win.addEventListener("keydown", key, true)
  return {
    stop() {
      win.removeEventListener("pointerdown", pointer, true)
      win.removeEventListener("keydown", key, true)
      delete root.dataset.input
    },
  }
}

function typing(el) {
  return !!el && (el.isContentEditable || el.tagName === "TEXTAREA" ||
    (el.tagName === "INPUT" && !/^(button|submit|reset|checkbox|radio|range|color|file|image)$/.test(el.type)))
}

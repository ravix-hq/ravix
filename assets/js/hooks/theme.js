// Which palette is on.
//
// The mechanism is one attribute. Every colour in `app.css` is a custom
// property declared under `[data-theme="…"]`, so setting that attribute on
// `<html>` re-themes the whole app, including any component written after
// this file, which is the point of the app never hard-coding a hex. The
// selectors are plain attribute selectors rather than `:root[data-theme]`,
// so a `<span data-theme="nord">` resolves `var(--bg)` to Nord's background:
// that is how the picker draws a live swatch per theme without a class per
// theme, and it means a swatch cannot drift from its palette.
//
// The saved palette lives in localStorage under `ravix.theme`, which the
// root layout's inline script also reads so the page paints in it before
// the stylesheet does. Two places holding one string is a thing that rots;
// `layouts_test.exs` asserts they still agree.
//
// The menu is pure client. Opening it, hovering a row to preview, choosing,
// and every way out (a choice, a click outside, Escape, the pointer leaving,
// the trigger again) never reach the server, because the server has nothing
// to say about a preference the browser keeps. What the hook expects:
//
//   <div phx-hook="Theme" id="theme-picker" class="theme-picker">
//     <button class="theme-trigger" data-theme-toggle aria-haspopup="menu">
//       <span class="theme-swatch" data-theme-swatch></span>
//       <span class="col"><small>Theme</small><span class="truncate" data-theme-name></span></span>
//     </button>
//     <div class="theme-menu" role="menu" hidden>
//       <button class="theme-option" role="menuitemradio" data-theme-choice="nord">
//         <span class="theme-swatch" data-theme="nord"></span><span>Nord</span>
//         <span class="check" data-theme-check hidden>…</span>
//       </button>
//       …
//     </div>
//   </div>
//
// The list of valid ids is whatever the picker offers: a saved value that no
// longer names a real theme resolves to the default rather than leaving
// `<html>` on an attribute that matches nothing.

export const THEME_KEY = "ravix.theme"
export const DEFAULT_THEME = "ravix"

function readSaved() {
  try {
    return localStorage.getItem(THEME_KEY)
  } catch {
    // A private window, or site data switched off. The default palette is
    // a complete answer, so this is not worth telling anybody about.
    return null
  }
}

function paint(id) {
  document.documentElement.setAttribute("data-theme", id)
}

function remember(id) {
  try {
    localStorage.setItem(THEME_KEY, id)
  } catch {
    // The theme still applies to this page; it just will not be remembered.
  }
}

export const Theme = {
  mounted() {
    this.ids = this.choices().map(el => el.dataset.themeChoice)
    const saved = readSaved()
    this.theme = this.ids.includes(saved) ? saved : DEFAULT_THEME
    // Re-applied through the validating path: the inline bootstrap trusted
    // whatever was saved so the first frame would be right.
    paint(this.theme)
    this.reflect()

    this.onClick = e => {
      const choice = e.target.closest("[data-theme-choice]")
      if (choice && this.el.contains(choice)) {
        this.choose(choice.dataset.themeChoice)
        return
      }
      if (e.target.closest("[data-theme-toggle]")) this.toggle()
    }
    this.onOver = e => {
      const choice = e.target.closest("[data-theme-choice]")
      if (choice && this.el.contains(choice)) paint(choice.dataset.themeChoice)
    }
    this.onLeave = e => {
      if (e.target === this.menu()) paint(this.theme)
    }
    this.onAway = e => {
      if (this.open && !this.el.contains(e.target)) this.close()
    }
    // Escape shuts this menu and nothing else: cancelling the key keeps a
    // popover the picker sits in (the account menu) open, the way the
    // browser's close requests promise, and focus goes back to the trigger
    // rather than to the body when it was on a row that is now hidden.
    this.onKey = e => {
      if (e.key !== "Escape" || !this.open) return
      e.preventDefault()
      const refocus = this.menu()?.contains(document.activeElement)
      this.close()
      if (refocus) this.trigger()?.focus()
    }
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("mouseover", this.onOver)
    this.el.addEventListener("focusin", this.onOver)
    this.el.addEventListener("mouseleave", this.onLeave, true)
    document.addEventListener("mousedown", this.onAway)
    document.addEventListener("keydown", this.onKey)
  },

  updated() {
    // A patch from the server re-renders the rows without the client's
    // choice on them; put it back.
    this.reflect()
  },

  destroyed() {
    document.removeEventListener("mousedown", this.onAway)
    document.removeEventListener("keydown", this.onKey)
  },

  choices() {
    return Array.from(this.el.querySelectorAll("[data-theme-choice]"))
  },

  menu() {
    return this.el.querySelector(".theme-menu")
  },

  choose(id) {
    this.theme = id
    paint(id)
    remember(id)
    this.reflect()
    this.close()
  },

  toggle() {
    if (this.open) this.close()
    else this.show()
  },

  show() {
    const menu = this.menu()
    if (!menu) return
    menu.hidden = false
    this.open = true
    this.trigger()?.setAttribute("aria-expanded", "true")
  },

  // A shut menu means the palette on screen is the one that was chosen,
  // whichever way out was taken.
  close() {
    const menu = this.menu()
    if (menu) menu.hidden = true
    this.open = false
    this.trigger()?.setAttribute("aria-expanded", "false")
    paint(this.theme)
  },

  trigger() {
    return this.el.querySelector("[data-theme-toggle]")
  },

  // The rows and the trigger say which palette is on.
  reflect() {
    let name = null
    for (const choice of this.choices()) {
      const on = choice.dataset.themeChoice === this.theme
      choice.classList.toggle("on", on)
      choice.setAttribute("aria-checked", on ? "true" : "false")
      const check = choice.querySelector("[data-theme-check]")
      if (check) check.hidden = !on
      if (on) name = choice.dataset.themeName || choice.textContent.trim()
    }
    const swatch = this.el.querySelector("[data-theme-swatch]")
    if (swatch) swatch.setAttribute("data-theme", this.theme)
    const label = this.el.querySelector("[data-theme-name]")
    if (label && name) label.textContent = name
  },
}

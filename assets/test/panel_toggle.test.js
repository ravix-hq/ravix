import {afterEach, expect, test} from "bun:test"
import {INSPECTOR_KEY, PanelToggle, YARD_KEY} from "../js/hooks/panel_toggle.js"
import {mountHook} from "./setup.js"

function markup({panel, key, hide, show}) {
  document.body.innerHTML = `<button id="toggle" data-panel="${panel}" data-key="${key}"
    data-hide-label="${hide}" data-show-label="${show}" aria-expanded="true" data-tip="${hide}" data-tip-kbd="Ctrl+B"></button>`
}

function mountYard() {
  markup({panel: "yard", key: YARD_KEY, hide: "Hide sidebar", show: "Show sidebar"})
  return mountHook(PanelToggle, "#toggle")
}

afterEach(() => {
  delete document.documentElement.dataset.yard
  delete document.documentElement.dataset.inspector
})

test("a sidebar starts open and a click closes it, then opens it again", () => {
  const {hook} = mountYard()
  expect(document.documentElement.dataset.yard).toBeUndefined()
  expect(hook.el.getAttribute("aria-expanded")).toBe("true")
  expect(hook.el.dataset.tip).toBe("Hide sidebar")
  expect(localStorage.getItem(YARD_KEY)).toBeNull()

  hook.el.click()
  expect(document.documentElement.dataset.yard).toBe("closed")
  expect(hook.el.getAttribute("aria-expanded")).toBe("false")
  expect(hook.el.dataset.tip).toBe("Show sidebar")
  expect(localStorage.getItem(YARD_KEY)).toBe("closed")

  hook.el.click()
  expect(document.documentElement.dataset.yard).toBeUndefined()
  expect(hook.el.getAttribute("aria-expanded")).toBe("true")
  expect(hook.el.dataset.tip).toBe("Hide sidebar")
  expect(localStorage.getItem(YARD_KEY)).toBe("open")
})

test("a closed sidebar is restored, and a server patch cannot report it as open", () => {
  localStorage.setItem(YARD_KEY, "closed")
  const {hook} = mountYard()
  expect(document.documentElement.dataset.yard).toBe("closed")
  expect(hook.el.getAttribute("aria-expanded")).toBe("false")
  expect(hook.el.dataset.tip).toBe("Show sidebar")

  hook.el.setAttribute("aria-expanded", "true")
  hook.el.dataset.tip = "Hide sidebar"
  hook.updated()
  expect(hook.el.getAttribute("aria-expanded")).toBe("false")
  expect(hook.el.dataset.tip).toBe("Show sidebar")
})

test("anything other than closed leaves the sidebar open", () => {
  localStorage.setItem(INSPECTOR_KEY, "maybe")
  markup({
    panel: "inspector",
    key: INSPECTOR_KEY,
    hide: "Hide inspector",
    show: "Show inspector",
  })
  const {hook} = mountHook(PanelToggle, "#toggle")
  expect(document.documentElement.dataset.inspector).toBeUndefined()
  hook.el.click()
  expect(document.documentElement.dataset.inspector).toBe("closed")
  expect(localStorage.getItem(INSPECTOR_KEY)).toBe("closed")
  expect(hook.el.dataset.tip).toBe("Show inspector")
})

test("a control that names no sidebar does nothing", () => {
  document.body.innerHTML = `<button id="toggle" data-panel="nope" aria-expanded="true"></button>`
  const {hook} = mountHook(PanelToggle, "#toggle")
  hook.el.click()
  hook.updated()
  expect(document.documentElement.dataset.nope).toBeUndefined()
  expect(hook.el.getAttribute("aria-expanded")).toBe("true")
})

test("a browser that refuses storage still toggles for this visit", () => {
  const get = Storage.prototype.getItem
  const set = Storage.prototype.setItem
  Storage.prototype.getItem = () => {
    throw new Error("blocked")
  }
  Storage.prototype.setItem = () => {
    throw new Error("blocked")
  }

  try {
    const {hook} = mountYard()
    expect(document.documentElement.dataset.yard).toBeUndefined()
    hook.el.click()
    expect(document.documentElement.dataset.yard).toBe("closed")
    hook.el.click()
    expect(document.documentElement.dataset.yard).toBeUndefined()
  } finally {
    Storage.prototype.getItem = get
    Storage.prototype.setItem = set
  }
})

// RAV-96: Ctrl/⌘B shows and hides the yard while its toggle is on screen.
test("the sidebar's shortcut clicks its toggle, and nothing else does", () => {
  document.body.innerHTML = `<button id="toggle" data-panel="yard" data-key="${YARD_KEY}" data-shortcut="b"
    data-hide-label="Hide sidebar" data-show-label="Show sidebar" data-tip-kbd="⌘B" aria-expanded="true"></button>`
  const {hook} = mountHook(PanelToggle, "#toggle")
  const press = options => {
    const event = new KeyboardEvent("keydown", {key: "b", bubbles: true, cancelable: true, ...options})
    window.dispatchEvent(event)
    return event
  }
  // Not drawn (a phone's drawer): the key is left to the browser.
  hook.el.getClientRects = () => []
  expect(press({metaKey: true}).defaultPrevented).toBe(false)
  expect(document.documentElement.dataset.yard).toBeUndefined()

  hook.el.getClientRects = () => [{}]
  expect(press({metaKey: true}).defaultPrevented).toBe(true)
  expect(document.documentElement.dataset.yard).toBe("closed")
  expect(hook.el.dataset.tip).toBe("Show sidebar")
  expect(hook.el.dataset.tipKbd).toBe("⌘B")
  press({key: "B", ctrlKey: true})
  expect(document.documentElement.dataset.yard).toBeUndefined()

  for (const options of [{}, {ctrlKey: true, shiftKey: true}, {metaKey: true, altKey: true}, {metaKey: true, repeat: true}, {ctrlKey: true, key: "k"}]) {
    expect(press(options).defaultPrevented).toBe(false)
  }
  expect(document.documentElement.dataset.yard).toBeUndefined()
  const handled = new KeyboardEvent("keydown", {key: "b", metaKey: true, cancelable: true})
  handled.preventDefault()
  window.dispatchEvent(handled)
  expect(document.documentElement.dataset.yard).toBeUndefined()

  hook.destroyed()
  press({metaKey: true})
  expect(document.documentElement.dataset.yard).toBeUndefined()
})

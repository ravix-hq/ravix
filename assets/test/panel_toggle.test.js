import {afterEach, expect, test} from "bun:test"
import {INSPECTOR_KEY, PanelToggle, YARD_KEY} from "../js/hooks/panel_toggle.js"
import {mountHook} from "./setup.js"

function markup({panel, key, hide, show}) {
  document.body.innerHTML = `<button id="toggle" data-panel="${panel}" data-key="${key}"
    data-hide-label="${hide}" data-show-label="${show}" aria-expanded="true" title="${hide}"></button>`
}

function mountYard() {
  markup({panel: "yard", key: YARD_KEY, hide: "Hide projects", show: "Show projects"})
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
  expect(hook.el.title).toBe("Hide projects")
  expect(localStorage.getItem(YARD_KEY)).toBeNull()

  hook.el.click()
  expect(document.documentElement.dataset.yard).toBe("closed")
  expect(hook.el.getAttribute("aria-expanded")).toBe("false")
  expect(hook.el.title).toBe("Show projects")
  expect(localStorage.getItem(YARD_KEY)).toBe("closed")

  hook.el.click()
  expect(document.documentElement.dataset.yard).toBeUndefined()
  expect(hook.el.getAttribute("aria-expanded")).toBe("true")
  expect(hook.el.title).toBe("Hide projects")
  expect(localStorage.getItem(YARD_KEY)).toBe("open")
})

test("a closed sidebar is restored, and a server patch cannot report it as open", () => {
  localStorage.setItem(YARD_KEY, "closed")
  const {hook} = mountYard()
  expect(document.documentElement.dataset.yard).toBe("closed")
  expect(hook.el.getAttribute("aria-expanded")).toBe("false")
  expect(hook.el.title).toBe("Show projects")

  hook.el.setAttribute("aria-expanded", "true")
  hook.el.title = "Hide projects"
  hook.updated()
  expect(hook.el.getAttribute("aria-expanded")).toBe("false")
  expect(hook.el.title).toBe("Show projects")
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
  expect(hook.el.title).toBe("Show inspector")
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

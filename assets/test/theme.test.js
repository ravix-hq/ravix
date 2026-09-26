import {beforeEach, expect, test} from "bun:test"
import {Theme} from "../js/hooks/theme.js"
import {key, mountHook} from "./setup.js"

beforeEach(() => {
  document.body.innerHTML = `<div class="theme-picker"><button data-theme-toggle><span data-theme-name></span><span data-theme-swatch></span></button>
  <div class="theme-menu" hidden><button data-theme-choice="ravix" data-theme-name="Ravix"><span data-theme-check></span>Ravix</button>
  <button data-theme-choice="nord" data-theme-name="Nord"><span data-theme-check></span>Nord</button></div></div><button id="outside">Outside</button>`
})

test("saved themes restore and invalid preferences resolve to the default", () => {
  localStorage.setItem("ravix.theme", "not-a-theme")
  const {hook} = mountHook(Theme, ".theme-picker")
  expect(document.documentElement.dataset.theme).toBe("ravix")
  expect(document.querySelector("[data-theme-name]").textContent).toBe("Ravix")
  hook.el.querySelector("[data-theme-toggle]").click()
  expect(hook.menu().hidden).toBe(false)
  hook.el.querySelector("[data-theme-choice=nord]").click()
  expect(localStorage.getItem("ravix.theme")).toBe("nord")
  expect(hook.menu().hidden).toBe(true)
  expect(hook.trigger().getAttribute("aria-expanded")).toBe("false")
  hook.updated()
  expect(hook.el.querySelector("[data-theme-choice=nord]").getAttribute("aria-checked")).toBe("true")
})

test("hover preview rolls back on escape, outside click, menu leave, and trigger toggle", () => {
  localStorage.setItem("ravix.theme", "nord")
  const {hook} = mountHook(Theme, ".theme-picker")
  expect(document.documentElement.dataset.theme).toBe("nord")
  const option = hook.el.querySelector("[data-theme-choice=ravix]")
  for (const close of [
    () => key(document, "Escape"),
    () => document.querySelector("#outside").dispatchEvent(new MouseEvent("mousedown",{bubbles:true})),
    () => hook.trigger().click(),
  ]) {
    hook.trigger().click()
    option.dispatchEvent(new MouseEvent("mouseover",{bubbles:true}))
    expect(document.documentElement.dataset.theme).toBe("ravix")
    close()
    expect(document.documentElement.dataset.theme).toBe("nord")
    expect(hook.menu().hidden).toBe(true)
  }
  hook.trigger().click()
  option.dispatchEvent(new FocusEvent("focusin",{bubbles:true}))
  hook.menu().dispatchEvent(new MouseEvent("mouseleave"))
  expect(document.documentElement.dataset.theme).toBe("nord")
})

test("escape closes only the palette list and gives focus back to its trigger", () => {
  const {hook} = mountHook(Theme, ".theme-picker")
  // Closed, Escape is somebody else's: an enclosing popover must still get it.
  expect(key(document, "Escape").defaultPrevented).toBe(false)
  hook.trigger().click()
  hook.el.querySelector("[data-theme-choice=nord]").focus()
  const escape = key(document, "Escape")
  expect(escape.defaultPrevented).toBe(true)
  expect(hook.menu().hidden).toBe(true)
  expect(document.activeElement).toBe(hook.trigger())
  // Opened by pointer with focus elsewhere, closing leaves focus alone.
  hook.trigger().click()
  document.querySelector("#outside").focus()
  key(document, "Escape")
  expect(document.activeElement).toBe(document.querySelector("#outside"))
})

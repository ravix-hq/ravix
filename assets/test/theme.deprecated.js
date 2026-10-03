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

test("a choice in one picker is the other's too, and a picker that has gone stops listening (RAV-77)", () => {
  // The You menu's picker and the Appearance page's, both on the page.
  const picker = document.querySelector(".theme-picker").outerHTML
  document.body.innerHTML = `<div id="menu-picker">${picker}</div><div id="page-picker">${picker}</div>`
  const {hook: menu} = mountHook(Theme, "#menu-picker .theme-picker")
  const {hook: page} = mountHook(Theme, "#page-picker .theme-picker")
  page.trigger().click()
  page.el.querySelector("[data-theme-choice=nord]").click()
  expect(document.documentElement.dataset.theme).toBe("nord")
  expect(menu.el.querySelector("[data-theme-name]").textContent).toBe("Nord")
  expect(menu.el.querySelector("[data-theme-choice=nord]").getAttribute("aria-checked")).toBe("true")

  // Hovering the menu's list and leaving it goes back to the choice made on
  // the page, not to what the menu held before.
  menu.trigger().click()
  menu.el.querySelector("[data-theme-choice=ravix]").dispatchEvent(new MouseEvent("mouseover", {bubbles: true}))
  expect(document.documentElement.dataset.theme).toBe("ravix")
  key(document, "Escape")
  expect(document.documentElement.dataset.theme).toBe("nord")

  // A name neither offers is not taken up.
  window.dispatchEvent(new CustomEvent("ravix:theme-changed", {detail: {id: "not-a-theme"}}))
  expect(menu.theme).toBe("nord")

  page.destroyed()
  menu.trigger().click()
  menu.el.querySelector("[data-theme-choice=ravix]").click()
  expect(page.theme).toBe("nord")
})

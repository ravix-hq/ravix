import {beforeEach, expect, test} from "bun:test"
import {ShareMention} from "../js/hooks/share_mention.js"
import {key, mountHook} from "./setup.js"

function options(logins, {hidden = false} = {}) {
  return `<ul id="share-person-options" role="listbox" ${hidden ? "hidden" : ""}>${logins
    .map(l => `<li id="share-option-${l}" role="option" aria-selected="false" data-login="${l}">@${l}</li>`)
    .join("")}</ul>`
}

function render(logins, opts) {
  document.body.innerHTML = `<div id="dialog"><form id="share-person-form">
    <input id="share-person" role="combobox" aria-controls="share-person-options" aria-expanded="true" />
    ${options(logins, opts)}</form></div>`
}

const input = () => document.getElementById("share-person")
const selected = () =>
  Array.from(document.querySelectorAll("[role=option][aria-selected=true]")).map(o => o.dataset.login)

beforeEach(() => render(["ana", "bo", "cy"]))

test("the first member offered is highlighted and named by aria-activedescendant", () => {
  mountHook(ShareMention, "#share-person-form")
  expect(selected()).toEqual(["ana"])
  expect(input().getAttribute("aria-activedescendant")).toBe("share-option-ana")
})

test("arrow keys move the highlight and wrap around", () => {
  mountHook(ShareMention, "#share-person-form")
  expect(key(input(), "ArrowDown").defaultPrevented).toBe(true)
  expect(selected()).toEqual(["bo"])
  key(input(), "ArrowDown")
  key(input(), "ArrowDown")
  expect(selected()).toEqual(["ana"])
  key(input(), "ArrowUp")
  expect(selected()).toEqual(["cy"])
  expect(input().getAttribute("aria-activedescendant")).toBe("share-option-cy")
})

test("Enter adds the highlighted member through the dialog's component", () => {
  const {hook, events} = mountHook(ShareMention, "#share-person-form")
  key(input(), "ArrowDown")
  expect(key(input(), "Enter").defaultPrevented).toBe(true)
  expect(events).toEqual([{name: "add", payload: {login: "bo"}, target: hook.el}])
})

test("Escape closes the list without reaching the dialog's own Escape", () => {
  mountHook(ShareMention, "#share-person-form")
  let reached = false
  document.getElementById("dialog").addEventListener("keydown", () => (reached = true))
  expect(key(input(), "Escape").defaultPrevented).toBe(true)
  expect(reached).toBe(false)
  expect(document.getElementById("share-person-options").hidden).toBe(true)
  expect(input().getAttribute("aria-expanded")).toBe("false")
  expect(input().hasAttribute("aria-activedescendant")).toBe(false)
  // Closed, the keys are the input's and the dialog's again.
  let later = false
  document.getElementById("dialog").addEventListener("keydown", () => (later = true))
  expect(key(input(), "Escape").defaultPrevented).toBe(false)
  expect(later).toBe(true)
})

test("with no list, keys pass through and Enter submits the typed name", () => {
  render([], {hidden: true})
  const {events} = mountHook(ShareMention, "#share-person-form")
  expect(input().hasAttribute("aria-activedescendant")).toBe(false)
  expect(key(input(), "Enter").defaultPrevented).toBe(false)
  expect(key(input(), "ArrowDown").defaultPrevented).toBe(false)
  expect(events).toEqual([])
})

test("keys while composing text are the input method's", () => {
  mountHook(ShareMention, "#share-person-form")
  expect(key(input(), "ArrowDown", {isComposing: true}).defaultPrevented).toBe(false)
  expect(selected()).toEqual(["ana"])
})

test("a patch keeps the highlighted member if still offered, else the first", () => {
  const {hook} = mountHook(ShareMention, "#share-person-form")
  key(input(), "ArrowDown")
  document.getElementById("share-person-options").outerHTML = options(["ana", "bo"])
  hook.updated()
  expect(selected()).toEqual(["bo"])
  document.getElementById("share-person-options").outerHTML = options(["cy"])
  hook.updated()
  expect(selected()).toEqual(["cy"])
  document.getElementById("share-person-options").outerHTML = options([], {hidden: true})
  hook.updated()
  expect(input().hasAttribute("aria-activedescendant")).toBe(false)
})

test("destroyed removes the key listener", () => {
  const {hook, events} = mountHook(ShareMention, "#share-person-form")
  hook.destroyed()
  key(input(), "Enter")
  expect(events).toEqual([])
})

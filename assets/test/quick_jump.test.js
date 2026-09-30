import {afterEach, expect, test} from "bun:test"
import {QuickJump, QuickJumpQuery} from "../js/hooks/quick_jump.js"
import {macPlatform} from "../js/platform.js"
import {key, mountHook} from "./setup.js"

// RAV-99: ⌘K on a Mac and Ctrl+K elsewhere open quick jump from anywhere but
// a terminal or another open dialog, and every key typed before its query
// field is ready ends up in that field.
function render(platform = "Linux x86_64") {
  Object.defineProperty(navigator, "platform", {value: platform, configurable: true})
  document.body.innerHTML = `<div id="workspace">
    <button id="trigger" data-quick-jump-trigger>Search</button>
    <textarea id="composer"></textarea>
    <input id="field">
    <div class="xterm"><textarea id="xterm-input" class="xterm-helper-textarea"></textarea></div>
    <div phx-hook="Terminal" id="terminal"><input id="command" data-terminal-input></div>
    <div id="dialogs"></div>
  </div>`
  const trigger = document.querySelector("#trigger")
  trigger.getClientRects = () => [{}]
  const opened = []
  trigger.addEventListener("click", () => opened.push(document.activeElement.id))
  const {hook} = mountHook(QuickJump, "#workspace")
  return {trigger, opened, hook}
}

// What the server's patch draws: the dialog and its query field, whose hook
// mounts in the same patch.
function openSearch(value = "") {
  document.querySelector("#dialogs").innerHTML = `<div id="search-dialog" class="scrim"><div role="dialog">
    <form id="search-form"><input id="search-query" name="q" value="${value}"></form>
    <a id="result" href="#a" data-jump-result>A</a></div></div>`
  const input = document.querySelector("#search-query")
  const changes = []
  input.addEventListener("input", () => changes.push(input.value))
  mountHook(QuickJumpQuery, "#search-query")
  return {input, changes}
}

afterEach(() => Object.defineProperty(navigator, "platform", {value: "Linux x86_64", configurable: true}))

test("the platform decides the modifier, for the binding and the server's label", () => {
  expect(macPlatform({platform: "MacIntel"})).toBe(true)
  expect(macPlatform({userAgentData: {platform: "macOS"}, platform: "Linux"})).toBe(true)
  expect(macPlatform({platform: "Linux x86_64"})).toBe(false)
  expect(macPlatform({})).toBe(false)
  expect(macPlatform(undefined)).toBe(false)
})

for (const [platform, modifier, other] of [["MacIntel", "metaKey", "ctrlKey"], ["Linux x86_64", "ctrlKey", "metaKey"]]) {
  test(`${platform}: the platform's K opens search globally, a field included`, () => {
    const {opened} = render(platform)
    // The other platform's modifier, and the Shift/Alt variants, are not it.
    for (const init of [{[other]: true}, {[modifier]: true, shiftKey: true}, {[modifier]: true, altKey: true}, {}]) {
      expect(key(document.body, "k", init).defaultPrevented).toBe(false)
    }
    expect(opened).toEqual([])
    const composer = document.querySelector("#composer")
    composer.focus()
    expect(key(composer, "k", {[modifier]: true}).defaultPrevented).toBe(true)
    expect(key(document.querySelector("#field"), "K", {[modifier]: true}).defaultPrevented).toBe(true)
    expect(key(document.body, "k", {[modifier]: true}).defaultPrevented).toBe(true)
    // Through the trigger, focused, so the dialog returns focus there.
    expect(opened).toEqual(["trigger", "trigger", "trigger"])
  })
}

test("a terminal keeps Ctrl+K for its shell", () => {
  const {opened} = render()
  for (const id of ["xterm-input", "command"]) {
    expect(key(document.getElementById(id), "k", {ctrlKey: true}).defaultPrevented).toBe(false)
  }
  expect(opened).toEqual([])
})

test("another open dialog keeps the key; a closing one does not", () => {
  const {opened} = render()
  document.querySelector("#dialogs").innerHTML = `<div id="share-dialog" class="scrim"><div role="dialog"><input id="share"></div></div>`
  expect(key(document.querySelector("#share"), "k", {ctrlKey: true}).defaultPrevented).toBe(false)
  document.querySelector("#dialogs").innerHTML = `<dialog open><input id="native"></dialog>`
  expect(key(document.querySelector("#native"), "k", {ctrlKey: true}).defaultPrevented).toBe(false)
  expect(opened).toEqual([])
  document.querySelector("#dialogs").innerHTML = `<div id="share-dialog" class="scrim" hidden><div role="dialog"></div></div>`
  expect(key(document.body, "k", {ctrlKey: true}).defaultPrevented).toBe(true)
  expect(opened).toHaveLength(1)
})

test("pressed again in search, the key goes back to the query and selects it", () => {
  const {opened} = render()
  const {input} = openSearch("alpha")
  const result = document.querySelector("#result")
  result.focus()
  expect(key(result, "k", {ctrlKey: true}).defaultPrevented).toBe(true)
  expect(document.activeElement).toBe(input)
  expect([input.selectionStart, input.selectionEnd]).toEqual([0, 5])
  expect(opened).toEqual([])
})

test("keys typed before the query mounts are held, then typed into it", () => {
  const {opened} = render()
  const composer = document.querySelector("#composer")
  composer.focus()
  key(composer, "k", {ctrlKey: true})
  expect(opened).toEqual(["trigger"])
  const trigger = document.querySelector("#trigger")
  const sent = []
  trigger.addEventListener("keydown", event => sent.push(event.key))
  // Printable keys and Backspace edit the held text; Enter (which would
  // press the trigger again) is swallowed; shortcuts and other keys pass.
  const presses = ["r", "a", "x", "Backspace", "v", " ", "2", "Enter"].map(name => key(trigger, name))
  expect(presses.every(event => event.defaultPrevented)).toBe(true)
  expect(key(trigger, "c", {ctrlKey: true}).defaultPrevented).toBe(false)
  expect(key(trigger, "Tab").defaultPrevented).toBe(false)
  expect(sent).toEqual(["c", "Tab"])
  expect(composer.value).toBe("")

  const {input, changes} = openSearch()
  expect(document.activeElement).toBe(input)
  expect(input.value).toBe("rav 2")
  expect(changes).toEqual(["rav 2"])
  expect(input.selectionStart).toBe(5)
  // Once it is there, keys are the field's own.
  expect(key(input, "x").defaultPrevented).toBe(false)
})

test("a click on the trigger holds keys too, the trigger's Space included", () => {
  const {trigger} = render()
  trigger.focus()
  trigger.click()
  expect(key(trigger, " ").defaultPrevented).toBe(true)
  expect(key(trigger, "a").defaultPrevented).toBe(true)
  const {input} = openSearch()
  expect(input.value).toBe(" a")
})

test("the query takes focus as it mounts even with nothing held, keeping a value", () => {
  render()
  const {input, changes} = openSearch("beta")
  expect(document.activeElement).toBe(input)
  expect(input.value).toBe("beta")
  expect(input.selectionStart).toBe(4)
  expect(changes).toEqual([])
})

test("Escape, or a dialog that never opens, stops holding keys", async () => {
  render()
  key(document.body, "k", {ctrlKey: true})
  expect(key(document.body, "Escape").defaultPrevented).toBe(false)
  expect(key(document.body, "a").defaultPrevented).toBe(false)

  const realTimeout = globalThis.setTimeout
  let expire
  globalThis.setTimeout = (fn) => { expire = fn; return 0 }
  try { key(document.body, "k", {ctrlKey: true}) } finally { globalThis.setTimeout = realTimeout }
  expect(key(document.body, "a").defaultPrevented).toBe(true)
  expire()
  expect(key(document.body, "b").defaultPrevented).toBe(false)
  const {input} = openSearch()
  expect(input.value).toBe("")
})

test("typing on a highlighted result goes on typing in the query", () => {
  render()
  const {input} = openSearch("al")
  const result = document.querySelector("#result")
  result.focus()
  expect(key(result, "p").defaultPrevented).toBe(false)
  expect(document.activeElement).toBe(input)
  result.focus()
  key(result, "c", {ctrlKey: true})
  expect(document.activeElement).toBe(result)
})

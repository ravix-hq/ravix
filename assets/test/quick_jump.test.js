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

// Arrow keys and Enter over the results, moved here from the project tree's
// tests when the sidebar went.
// `dispatchEvent`'s answer: false when the hook took the key.
const press = (el, name, options = {}) =>
  el.dispatchEvent(new KeyboardEvent('keydown', {key: name, bubbles: true, cancelable: true, ...options}))
test('quick-jump chooses the visible trigger, arrows wrap and Enter opens the first result', () => {
  document.body.innerHTML = `<div id="workspace"><button data-quick-jump-trigger id="desktop">Search</button><button data-quick-jump-trigger id="mobile">Search</button></div>`
  const mobile = document.querySelector('#mobile')
  document.querySelector('#desktop').getClientRects = () => []
  mobile.getClientRects = () => [{}]
  let opened = 0
  mobile.onclick = () => { opened++ }
  const {hook} = mountHook(QuickJump, '#workspace')
  press(window, 'K', {ctrlKey: true})
  press(window, 'k', {ctrlKey: true})
  expect(opened).toBe(2)
  document.querySelector('#workspace').insertAdjacentHTML('beforeend', `<div id="search-dialog" class="scrim"><div role="dialog"><input id="search-query"><a href="#a" data-jump-result>A</a><a href="#b" data-jump-result>B</a></div></div>`)
  press(window, 'k', {ctrlKey: true})
  expect(opened).toBe(2)
  const input = document.querySelector('input'), [a,b] = document.querySelectorAll('a')
  input.focus(); press(input, 'ArrowDown'); expect(document.activeElement).toBe(a)
  press(a, 'ArrowUp'); expect(document.activeElement).toBe(b)
  press(b, 'ArrowDown'); expect(document.activeElement).toBe(a)
  input.focus(); press(input, 'ArrowUp'); expect(document.activeElement).toBe(b)
  let selected = 0; a.onclick = event => { event.preventDefault(); selected++ }
  input.focus(); press(input, 'Enter'); expect(selected).toBe(1)
  press(input, 'x'); press(mobile, 'ArrowDown')
  a.remove(); b.remove(); press(input, 'ArrowDown')
  hook.destroyed()
  document.querySelector('#search-dialog').remove()
  press(window, 'k', {ctrlKey: true}); expect(opened).toBe(2)
})

test('quick-jump keeps selected result focus when filtering moves its row', () => {
  document.body.innerHTML = `<div id="workspace"><input id="search-query"><a id="result" data-jump-result href="#project">Project</a></div>`
  const {hook} = mountHook(QuickJump, '#workspace')
  const input = document.querySelector('input'), link = document.querySelector('a')
  link.focus(); hook.beforeUpdate()
  link.remove(); document.querySelector('#workspace').append(link)
  hook.updated(); expect(document.activeElement).toBe(link)
  hook.beforeUpdate(); input.focus(); hook.updated(); expect(document.activeElement).toBe(input)
  hook.beforeUpdate(); hook.updated(); expect(document.activeElement).toBe(input)
  link.focus(); hook.beforeUpdate(); link.remove(); hook.updated()
  expect(document.activeElement).toBe(document.body)
})

test('quick-jump keys also move through a data-jump-scope list, skipping disabled results', () => {
  document.body.innerHTML = `<div id="workspace"><div id="repo-picker" data-jump-scope>
    <input id="repo-picker-query" data-jump-query>
    <button id="a" data-jump-result>acme/api</button>
    <button id="off" data-jump-result disabled>acme/busy</button>
    <button id="b" data-jump-result>acme/web</button>
  </div><input id="elsewhere"></div>`
  const {hook} = mountHook(QuickJump, '#workspace')
  const query = document.querySelector('#repo-picker-query')
  let picked = null
  document.querySelector('#a').addEventListener('click', () => { picked = 'a' })
  query.focus()
  expect(press(query, 'ArrowDown')).toBe(false)
  expect(document.activeElement.id).toBe('a')
  press(document.activeElement, 'ArrowDown')
  expect(document.activeElement.id).toBe('b')
  press(document.activeElement, 'ArrowDown')
  expect(document.activeElement.id).toBe('a')
  press(document.activeElement, 'ArrowUp')
  expect(document.activeElement.id).toBe('b')
  expect(press(query, 'Enter')).toBe(false)
  expect(picked).toBe('a')
  // Outside any scope the keys are left alone.
  const elsewhere = document.querySelector('#elsewhere')
  expect(press(elsewhere, 'ArrowDown')).toBe(true)
  hook.destroyed()
})

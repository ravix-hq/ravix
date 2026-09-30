import {afterEach, expect, test} from "bun:test"
import {QuickJump} from "../js/hooks/quick_jump.js"
import {key, mountHook} from "./setup.js"

// Cmd/Ctrl+N opens New track (RAV-60) through the visible New track button,
// as Cmd/Ctrl+K opens search; wherever it cannot help, the key is left to
// the browser's own new window.
function render(platform) {
  Object.defineProperty(navigator, "platform", {value: platform, configurable: true})
  document.body.innerHTML = `<div id="workspace">
    <button id="hidden-new" data-new-track-trigger>New track</button>
    <button id="new" data-new-track-trigger>New track</button>
    <textarea id="composer"></textarea>
    <div class="xterm"><span id="terminal">$</span></div>
  </div>`
  const button = document.querySelector("#new")
  button.getClientRects = () => [{}]
  document.querySelector("#hidden-new").getClientRects = () => []
  const opened = []
  button.addEventListener("click", () => opened.push(document.activeElement.id))
  const {hook} = mountHook(QuickJump, "#workspace")
  return {button, opened, hook}
}

afterEach(() => Object.defineProperty(navigator, "platform", {value: "Linux x86_64", configurable: true}))

for (const [platform, modifier, other] of [["MacIntel", "metaKey", "ctrlKey"], ["Linux x86_64", "ctrlKey", "metaKey"]]) {
  test(`${platform}: the platform's N opens New track from the page and from a field`, () => {
    const {opened} = render(platform)
    expect(key(document.body, "n", {[modifier]: true}).defaultPrevented).toBe(true)
    expect(key(document.querySelector("#composer"), "N", {[modifier]: true}).defaultPrevented).toBe(true)
    // It clicks the visible button, focused, so the dialog returns focus there.
    expect(opened).toEqual(["new", "new"])

    // The other platform's modifier, and the Shift/Alt variants (a private
    // window, a typed character), stay the browser's.
    for (const init of [{[other]: true}, {[modifier]: true, shiftKey: true}, {[modifier]: true, altKey: true}, {}]) {
      expect(key(document.body, "n", init).defaultPrevented).toBe(false)
    }
    expect(opened).toHaveLength(2)
  })
}

test("a terminal keeps Ctrl+N for its shell", () => {
  const {opened} = render("Linux x86_64")
  expect(key(document.querySelector("#terminal"), "n", {ctrlKey: true}).defaultPrevented).toBe(false)
  expect(opened).toEqual([])
})

test("an open dialog keeps the key, so the browser's new window still works", () => {
  const {opened} = render("Linux x86_64")
  document.querySelector("#workspace").insertAdjacentHTML("beforeend", `<div role="dialog"></div>`)
  expect(key(document.body, "n", {ctrlKey: true}).defaultPrevented).toBe(false)
  expect(opened).toEqual([])
})

test("with no visible or enabled New track button the key is not taken", () => {
  const {button, opened} = render("Linux x86_64")
  button.disabled = true
  expect(key(document.body, "n", {ctrlKey: true}).defaultPrevented).toBe(false)
  button.remove()
  expect(key(document.body, "n", {ctrlKey: true}).defaultPrevented).toBe(false)
  expect(opened).toEqual([])
})

test("once the hook is gone the key is the browser's", () => {
  const {hook, opened} = render("Linux x86_64")
  hook.destroyed()
  expect(key(document.body, "n", {ctrlKey: true}).defaultPrevented).toBe(false)
  expect(opened).toEqual([])
})

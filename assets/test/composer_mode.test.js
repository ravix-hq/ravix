import {beforeEach, expect, setSystemTime, test} from "bun:test"
import {Composer} from "../js/hooks/composer.js"
import {key, mountHook} from "./setup.js"

// RAV-94: the "Ctrl+L to focus" hint is hidden while focus is anywhere in the
// composer. Ask agent / Comment switches in the browser when pressed, and the
// server's render, which may arrive after a patch drawn before the click,
// catches up without putting the old mode back on screen.

// What the server draws for `mode`, as a patch would write it.
function serverDraws(hook, mode, {askDisabled = false} = {}) {
  const box = hook.el.closest("[data-composer-box]")
  box.className = mode === "comment" ? "composer-box commenting" : "composer-box"
  for (const button of box.querySelectorAll("[data-composer-mode]")) {
    button.setAttribute("aria-pressed", String(button.dataset.composerMode === mode))
  }
  hook.el.dataset.mode = mode
  hook.el.placeholder = mode === "comment" ? hook.el.dataset.placeholderComment : hook.el.dataset.placeholderAsk
  hook.el.setAttribute("aria-label", mode === "comment" ? "Comment" : "Message")
  hook.el.disabled = mode === "ask" && askDisabled
  const send = box.querySelector(".composer-send")
  send.setAttribute("aria-label", mode === "comment" ? "Post comment" : "Send")
  send.title = send.getAttribute("aria-label")
  hook.updated()
}

function render({askDisabled = false} = {}) {
  document.body.innerHTML = `<form><div class="composer-box" data-composer-box>
    <textarea id="composer-t1" data-mode="ask" aria-label="Message" aria-controls="composer-suggestions"
      placeholder="Ask to make changes" data-placeholder-ask="Ask to make changes"
      data-placeholder-comment="Comment for people" data-ask-disabled="${askDisabled}"
      ${askDisabled ? "disabled" : ""}></textarea>
    <ul id="composer-suggestions" data-composer-suggestions hidden></ul>
    <div class="composer-mode">
      <button type="button" id="ask" data-composer-mode="ask" aria-pressed="true">Ask agent</button>
      <button type="button" id="comment" data-composer-mode="comment" aria-pressed="false">Comment</button>
    </div>
    <span id="composer-shortcut" data-composer-shortcut><kbd>Ctrl+L</kbd> to focus</span>
    <button class="composer-send" aria-label="Send" title="Send"></button>
  </div></form><button id="elsewhere">Elsewhere</button>`
  return mountHook(Composer, "textarea")
}

const box = () => document.querySelector("[data-composer-box]")
const pressed = () => document.querySelector("[aria-pressed=true]").id
const send = () => document.querySelector(".composer-send")

beforeEach(() => setSystemTime())

test("pressing Comment switches the box at once, before the server answers", () => {
  const {hook} = render()
  document.querySelector("#comment").click()
  expect(box().classList.contains("commenting")).toBe(true)
  expect(pressed()).toBe("comment")
  expect(hook.el.placeholder).toBe("Comment for people")
  expect(hook.el.getAttribute("aria-label")).toBe("Comment")
  expect(send().getAttribute("aria-label")).toBe("Post comment")
  expect(send().title).toBe("Post comment")
  // What the server drew is untouched: that is how its answer is recognised.
  expect(hook.el.dataset.mode).toBe("ask")
  expect(hook.mode()).toBe("comment")
})

test("a patch drawn before the click has the chosen mode put back over it", () => {
  const {hook} = render()
  document.querySelector("#comment").click()
  serverDraws(hook, "ask")
  expect(box().classList.contains("commenting")).toBe(true)
  expect(pressed()).toBe("comment")
  expect(hook.el.placeholder).toBe("Comment for people")

  // The server's own answer ends the wait; after it, what it draws stands.
  serverDraws(hook, "comment")
  expect(hook.pendingMode).toBeNull()
  serverDraws(hook, "ask")
  expect(box().classList.contains("commenting")).toBe(false)
  expect(pressed()).toBe("ask")
})

test("back to Ask is as quick, and a Read member's box is disabled again", () => {
  const {hook} = render({askDisabled: true})
  expect(hook.el.disabled).toBe(true)
  document.querySelector("#comment").click()
  // A Read member may comment, so the box opens with the switch.
  expect(hook.el.disabled).toBe(false)
  serverDraws(hook, "comment", {askDisabled: true})
  document.querySelector("#ask").click()
  expect(box().classList.contains("commenting")).toBe(false)
  expect(pressed()).toBe("ask")
  expect(hook.el.placeholder).toBe("Ask to make changes")
  expect(hook.el.getAttribute("aria-label")).toBe("Message")
  expect(send().getAttribute("aria-label")).toBe("Send")
  expect(hook.el.disabled).toBe(true)
})

test("Comment then Ask before either is drawn ends on Ask, whatever order patches arrive in", () => {
  const {hook} = render()
  document.querySelector("#comment").click()
  document.querySelector("#ask").click()
  expect(pressed()).toBe("ask")
  // The server's answer to the first press arrives first.
  serverDraws(hook, "comment")
  expect(pressed()).toBe("ask")
  expect(box().classList.contains("commenting")).toBe(false)
  serverDraws(hook, "ask")
  expect(hook.pendingMode).toBeNull()
  expect(pressed()).toBe("ask")
})

test("pressing the mode already shown waits for nothing", () => {
  const {hook} = render()
  document.querySelector("#ask").click()
  expect(hook.pendingMode).toBeNull()
  expect(pressed()).toBe("ask")
})

test("a server that never draws the chosen mode is believed after a while", () => {
  const {hook} = render()
  setSystemTime(new Date("2026-09-30T12:00:00Z"))
  document.querySelector("#comment").click()
  setSystemTime(new Date("2026-09-30T12:00:11Z"))
  serverDraws(hook, "ask")
  expect(hook.pendingMode).toBeNull()
  expect(pressed()).toBe("ask")
  expect(box().classList.contains("commenting")).toBe(false)
})

test("switching closes an open list, and Comment mode attaches no images", () => {
  const {hook} = render()
  hook.el.dataset.filesEvent = "mention-files"
  hook.el.value = "@"
  hook.el.setSelectionRange(1, 1)
  hook.el.dispatchEvent(new Event("input"))
  expect(document.querySelector("#composer-suggestions").hidden).toBe(false)
  document.querySelector("#comment").click()
  expect(document.querySelector("#composer-suggestions").hidden).toBe(true)
  // Until the server draws the people list, `@` finds no list to open.
  expect(hook.mentions()).toBeNull()
  expect(hook.suggestions()).toBeNull()
  expect(hook.attach([new File(["x"], "a.png", {type: "image/png"})])).toBe(true)
  expect(document.querySelector("[data-composer-note]")).toBeNull()
})

test("a box with no modes (a draft thread's) ignores the switch", () => {
  const {hook} = render()
  delete hook.el.dataset.mode
  hook.chooseMode("comment")
  expect(hook.pendingMode).toBeUndefined()
  expect(pressed()).toBe("ask")
  hook.el.dataset.mode = "ask"
  hook.chooseMode("shout")
  expect(pressed()).toBe("ask")
})

const hint = () => document.querySelector("[data-composer-shortcut]")

test("the focus hint hides while focus is in the composer, and returns when it leaves", () => {
  const {hook} = render()
  expect(hint().style.visibility).toBe("")
  hook.el.focus()
  expect(hint().style.visibility).toBe("hidden")
  // Moving within the composer, to its own buttons, keeps it hidden.
  document.querySelector("#comment").focus()
  expect(hint().style.visibility).toBe("hidden")
  document.querySelector("#elsewhere").focus()
  expect(hint().style.visibility).toBe("")
})

test("the hint starts hidden when the box already has focus, and ⌘L focuses it on a Mac's label", () => {
  render()
  document.querySelector("textarea").focus()
  // A second mount (a patch that replaced the box) finds focus already inside.
  const {hook} = mountHook(Composer, "textarea")
  expect(hint().style.visibility).toBe("hidden")
  document.querySelector("#elsewhere").focus()
  expect(hint().style.visibility).toBe("")
  key(document.querySelector("#elsewhere"), "l", {ctrlKey: true})
  expect(document.activeElement).toBe(hook.el)
  expect(hint().style.visibility).toBe("hidden")
  expect(hint().textContent).toMatch(/^(⌘L|Ctrl\+L) to focus$/)
})

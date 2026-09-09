import {beforeEach, expect, test} from "bun:test"
import {TranscriptTail} from "../js/hooks/transcript_tail.js"
import {dimensions, mountHook} from "./setup.js"

beforeEach(() => {
  document.body.innerHTML = `<div id="transcript" data-track="one" data-older-event="older"><div>
  <div class="code-block"><button class="code-copy">Copy</button><pre><code>&lt;literal&gt;\nline two</code></pre></div>
  <button data-jump-latest>Latest</button></div></div>`
  dimensions(document.querySelector("#transcript"),{scrollHeight:1000,clientHeight:200})
})

test("older pages preserve scroll position and requests coalesce until their patch", () => {
  const {hook,events} = mountHook(TranscriptTail,"#transcript")
  expect(hook.el.scrollTop).toBe(1000)
  hook.el.scrollTop = 100
  hook.el.dispatchEvent(new Event("scroll"))
  hook.el.dispatchEvent(new Event("scroll"))
  expect(events).toEqual([{name:"older",payload:{}}])
  expect(hook.el.classList.contains("unpinned")).toBe(true)
  hook.beforeUpdate()
  dimensions(hook.el,{scrollHeight:1500})
  hook.updated()
  expect(hook.el.scrollTop).toBe(600)
  hook.el.querySelector("[data-jump-latest]").click()
  expect(hook.el.scrollTop).toBe(1500)
  expect(hook.el.classList.contains("unpinned")).toBe(false)
})

test("track changes repin and text selection is never dragged away", () => {
  const {hook} = mountHook(TranscriptTail,"#transcript")
  hook.el.scrollTop = 100
  hook.el.dispatchEvent(new Event("scroll"))
  hook.beforeUpdate()
  hook.el.dataset.track = "two"
  hook.updated()
  expect(hook.el.scrollTop).toBe(1000)
  const range = document.createRange()
  range.selectNodeContents(hook.el.querySelector("code"))
  document.getSelection().addRange(range)
  hook.el.scrollTop = 500
  hook.updated()
  expect(hook.el.scrollTop).toBe(500)
  document.getSelection().removeAllRanges()
})

test("copy reports success or failure without losing literal code", async () => {
  const {hook} = mountHook(TranscriptTail,"#transcript")
  const writes = []
  Object.defineProperty(navigator,"clipboard",{configurable:true,value:{writeText:async text=>writes.push(text)}})
  const button = hook.el.querySelector(".code-copy")
  await hook.copy(button)
  expect(writes).toEqual(["<literal>\nline two"])
  expect(button.textContent).toBe("Copied!")
  expect(button.disabled).toBe(false)
  navigator.clipboard.writeText = async () => {throw new Error("denied")}
  await hook.copy(button)
  expect(button.getAttribute("aria-label")).toBe("Copy failed. Try again")
  expect(button.disabled).toBe(false)
})

test("delegated copy resets its label after feedback and tolerates removal", async () => {
  const {hook} = mountHook(TranscriptTail,"#transcript")
  Object.defineProperty(navigator,"clipboard",{configurable:true,value:{writeText:async ()=>{}}})
  const callbacks = []
  const schedule = window.setTimeout
  window.setTimeout = callback => {callbacks.push(callback); return 0}
  try {
    const button = hook.el.querySelector(".code-copy")
    button.click()
    await Promise.resolve()
    expect(button.textContent).toBe("Copied!")
    callbacks.shift()()
    expect(button.getAttribute("aria-label")).toBe("Copy code")
    await hook.copy(button)
    button.remove()
    callbacks.shift()()
  } finally {
    window.setTimeout = schedule
  }
})

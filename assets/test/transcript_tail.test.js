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

test("scrolling up shows the way back on the scroller itself, and taking it re-pins", () => {
  // The button is drawn hidden and the stylesheet shows it only under the
  // class this hook toggles on the scroller it is mounted on --- so the
  // class has to land on the element that carries `.transcript-scroll`, not
  // on a child, and the button has to be inside it.
  document.body.innerHTML = `<div id="transcript-scroll" class="transcript-scroll" data-track="one">
    <div class="track-ribbon">created</div>
    <div id="transcript-turns">turns</div>
    <button type="button" class="jump-latest" data-jump-latest>Jump to latest</button>
  </div>`
  const el = document.querySelector("#transcript-scroll")
  dimensions(el, {scrollHeight: 1000, clientHeight: 200})
  const {hook, events} = mountHook(TranscriptTail, "#transcript-scroll")
  expect(el.scrollTop).toBe(1000)
  expect(el.matches(".transcript-scroll.unpinned")).toBe(false)

  el.scrollTop = 300
  el.dispatchEvent(new Event("scroll"))
  expect(el.matches(".transcript-scroll.unpinned")).toBe(true)
  expect(document.querySelector(".transcript-scroll.unpinned .jump-latest")).toBe(el.querySelector("[data-jump-latest]"))
  // No paging is asked for: the scroller carries no `data-older-event`.
  expect(events).toEqual([])

  // Output landing while unpinned does not move the reader.
  hook.beforeUpdate()
  dimensions(el, {scrollHeight: 1400})
  hook.updated()
  expect(el.scrollTop).toBe(700)
  expect(el.matches(".unpinned")).toBe(true)

  el.querySelector("[data-jump-latest]").click()
  expect(el.scrollTop).toBe(1400)
  expect(el.matches(".unpinned")).toBe(false)
  // And pinned again: the next patch follows the bottom.
  hook.beforeUpdate()
  dimensions(el, {scrollHeight: 1800})
  hook.updated()
  expect(el.scrollTop).toBe(1800)

  // Back within reach of the bottom by scrolling counts as pinned too.
  el.scrollTop = 1700
  el.dispatchEvent(new Event("scroll"))
  expect(el.matches(".unpinned")).toBe(false)
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

test("growth is watched on the turns, not only on whatever is laid in above them", () => {
  // The real track page puts a fixed-height ribbon above the turns. Watching
  // only the first child left the growing element unobserved, so a reply
  // whose images or diffs land after the patch stopped following the bottom.
  document.body.innerHTML = `<div id="transcript" data-track="one"><div class="track-ribbon">created</div><div id="transcript-turns">turns</div></div>`
  const el = document.querySelector("#transcript")
  dimensions(el, {scrollHeight: 1000, clientHeight: 200})

  const observed = []
  const native = globalThis.ResizeObserver
  globalThis.ResizeObserver = class {
    observe(node) { observed.push(node) }
    disconnect() {}
  }
  try {
    const {hook} = mountHook(TranscriptTail, "#transcript")
    expect(observed).toContain(el.querySelector("#transcript-turns"))
    expect(observed).toContain(el.querySelector(".track-ribbon"))
    expect(observed).toContain(el)

    // Re-observing after a patch stays safe to repeat.
    observed.length = 0
    hook.updated()
    expect(observed).toContain(el.querySelector("#transcript-turns"))
  } finally {
    globalThis.ResizeObserver = native
  }
})

test("a turn's answer copies its markdown, says so, and resets", async () => {
  {
    const el = document.querySelector("#transcript > div")
    el.insertAdjacentHTML("beforeend", `<button data-copy="**The** answer" aria-label="Copy answer">c</button>`)
  }
  const {hook} = mountHook(TranscriptTail,"#transcript")
  const writes = []
  Object.defineProperty(navigator,"clipboard",{configurable:true,value:{writeText:async text=>writes.push(text)}})
  const callbacks = []
  const schedule = window.setTimeout
  window.setTimeout = callback => {callbacks.push(callback); return 0}
  try {
    const button = hook.el.querySelector("[data-copy]")
    button.click()
    await Promise.resolve()
    expect(writes).toEqual(["**The** answer"])
    expect(button.getAttribute("aria-label")).toBe("Answer copied")
    expect(button.classList.contains("copied")).toBe(true)
    callbacks.shift()()
    expect(button.getAttribute("aria-label")).toBe("Copy answer")
    expect(button.classList.contains("copied")).toBe(false)
    navigator.clipboard.writeText = async () => {throw new Error("denied")}
    await hook.copyAnswer(button)
    expect(button.getAttribute("aria-label")).toBe("Copy failed. Try again")
    button.disabled = true
    await hook.copyAnswer(button)
    expect(writes.length).toBe(1)
    button.disabled = false
    button.remove()
    callbacks.shift()()
  } finally {
    window.setTimeout = schedule
  }
})

test("UTC timestamps stay consistent with the inbox on mount and after a patch", () => {
  const el = document.querySelector("#transcript > div")
  el.insertAdjacentHTML("beforeend",
    `<time datetime="2026-09-26T13:01:00Z">13:01 UTC</time>`)
  const {hook} = mountHook(TranscriptTail,"#transcript")
  expect(hook.el.querySelector("time").textContent).toBe("13:01 UTC")
  el.insertAdjacentHTML("beforeend", `<time datetime="2026-09-26T14:30:00Z">14:30 UTC</time>`)
  hook.updated()
  expect(hook.el.querySelectorAll("time")[1].textContent).toBe("14:30 UTC")
})

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

test("a patch that rewrites the scroller's class attribute does not take the pill away", () => {
  // LiveView morphs `class` back to the server's value on every patch that
  // reaches the element; the classes this hook sets are its own state and
  // come back with the patch, not with the next scroll.
  document.body.innerHTML = `<div id="transcript-scroll" class="transcript-scroll" data-track="one">
    <div id="transcript-turns">turns</div>
    <button type="button" class="jump-latest" data-jump-latest>Jump to latest</button>
  </div>`
  const el = document.querySelector("#transcript-scroll")
  dimensions(el, {scrollHeight: 1000, clientHeight: 200})
  const {hook} = mountHook(TranscriptTail, "#transcript-scroll")

  el.scrollTop = 300
  el.dispatchEvent(new Event("scroll"))
  expect(el.className).toBe("transcript-scroll unpinned scrolled")

  // The patch: the server's class attribute, the hook's additions gone.
  hook.beforeUpdate()
  el.className = "transcript-scroll"
  hook.updated()
  expect(el.scrollTop).toBe(300)
  expect(el.matches(".transcript-scroll.unpinned.scrolled")).toBe(true)

  // Pinned at the bottom, a patch leaves the pill off; the bottom is still
  // scrolled away from the top.
  el.querySelector("[data-jump-latest]").click()
  hook.beforeUpdate()
  el.className = "transcript-scroll unpinned"
  hook.updated()
  expect(el.className).toBe("transcript-scroll scrolled")
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

test("a visible turn stays anchored when earlier history and live output arrive together", () => {
  const el = document.querySelector("#transcript")
  el.innerHTML += '<button id="load-earlier">Load earlier</button><div id="transcript-turns"><article id="turn-held">held</article></div>'
  const {hook} = mountHook(TranscriptTail, "#transcript")
  el.querySelector("#load-earlier").click()
  expect(hook.pinned).toBe(false)
  el.scrollTop = 100
  const held = el.querySelector("article")
  held.getBoundingClientRect = () => ({ top: 50, bottom: 200 })
  hook.beforeUpdate()
  dimensions(el, {scrollHeight: 2000})
  held.getBoundingClientRect = () => ({ top: 350, bottom: 500 })
  hook.updated()
  expect(el.scrollTop).toBe(400)
})

// RAV-93: the footer's ⋯ menu copies a link to the turn or its text, and
// says so on its trigger, since the menu closes as the item is picked.
test("the turn menu copies an absolute link or the text, and its trigger says so", async () => {
  document.querySelector("#transcript > div").insertAdjacentHTML("beforeend", `
    <div class="chip-menu"><button popovertarget="m" aria-label="More for this turn">⋯</button>
      <div id="m" popover>
        <button data-copy-link="/p/1/t/2?thread=3#turns-turn-4">Copy link to turn</button>
        <button data-copy-text="**The** answer">Copy text</button>
        <button data-copy-text="" disabled>Copy text</button>
      </div></div>`)
  const {hook} = mountHook(TranscriptTail, "#transcript")
  const writes = []
  Object.defineProperty(navigator, "clipboard", {configurable: true, value: {writeText: async text => writes.push(text)}})
  const callbacks = []
  const schedule = window.setTimeout
  window.setTimeout = callback => { callbacks.push(callback); return 0 }
  try {
    const trigger = hook.el.querySelector("[popovertarget]")
    hook.el.querySelector("[data-copy-link]").click()
    await Promise.resolve()
    expect(writes).toEqual([new URL("/p/1/t/2?thread=3#turns-turn-4", window.location.href).href])
    expect(writes[0]).toStartWith("http")
    expect(trigger.getAttribute("aria-label")).toBe("Link copied")
    expect(trigger.classList.contains("copied")).toBe(true)
    callbacks.shift()()
    expect(trigger.getAttribute("aria-label")).toBe("More for this turn")
    expect(trigger.classList.contains("copied")).toBe(false)

    hook.el.querySelector('[data-copy-text="**The** answer"]').click()
    await Promise.resolve()
    expect(writes[1]).toBe("**The** answer")
    expect(trigger.getAttribute("aria-label")).toBe("Text copied")
    callbacks.shift()()

    await hook.copyFromMenu(hook.el.querySelector("[data-copy-text][disabled]"), "", "Text copied")
    expect(writes.length).toBe(2)

    navigator.clipboard.writeText = async () => { throw new Error("denied") }
    await hook.copyFromMenu(hook.el.querySelector("[data-copy-link]"), "x", "Link copied")
    expect(trigger.getAttribute("aria-label")).toBe("Copy failed. Try again")
    trigger.remove()
    callbacks.shift()()
  } finally {
    window.setTimeout = schedule
  }
})

test("scrolling off the top marks the scroller so the edge under the tabs fades", () => {
  const {hook} = mountHook(TranscriptTail, "#transcript")
  hook.el.scrollTop = 300
  hook.el.dispatchEvent(new Event("scroll"))
  expect(hook.el.classList.contains("scrolled")).toBe(true)
  hook.el.scrollTop = 0
  hook.el.dispatchEvent(new Event("scroll"))
  expect(hook.el.classList.contains("scrolled")).toBe(false)
})

test("a printable key on the transcript is typed into the composer", () => {
  document.body.insertAdjacentHTML("beforeend",
    '<form id="composer-form"><textarea name="text"></textarea></form>')
  document.querySelector("#transcript > div").insertAdjacentHTML("beforeend",
    '<input id="inside"><div id="menu" popover><button id="item">i</button></div>')
  const {hook} = mountHook(TranscriptTail, "#transcript")
  const composer = document.querySelector("#composer-form textarea")
  const inputs = []
  composer.addEventListener("input", () => inputs.push(composer.value))
  const press = (target, init) => {
    const event = new KeyboardEvent("keydown", {bubbles: true, cancelable: true, ...init})
    target.dispatchEvent(event)
    return event
  }

  const typed = press(hook.el, {key: "h"})
  expect(typed.defaultPrevented).toBe(true)
  press(hook.el, {key: "i"})
  expect(composer.value).toBe("hi")
  expect(document.activeElement).toBe(composer)
  expect(inputs).toEqual(["h", "hi"])

  // Space scrolls; chords, named keys and a field's own keys are left alone.
  for (const [target, init] of [
    [hook.el, {key: " "}],
    [hook.el, {key: "c", ctrlKey: true}],
    [hook.el, {key: "k", metaKey: true}],
    [hook.el, {key: "ArrowDown"}],
    [hook.el.querySelector("#inside"), {key: "x"}],
    [hook.el.querySelector("#item"), {key: "x"}],
  ]) expect(press(target, init).defaultPrevented).toBe(false)
  expect(composer.value).toBe("hi")

  // A composer that cannot take text is not typed into.
  composer.disabled = true
  expect(press(hook.el, {key: "z"}).defaultPrevented).toBe(false)
  expect(composer.value).toBe("hi")
})

test("a URL naming a turn scrolls to it once the turns are drawn, and only once", () => {
  const el = document.querySelector("#transcript")
  const original = window.location.href
  window.history.replaceState(null, "", "#turns-turn-2")
  try {
    el.insertAdjacentHTML("beforeend", '<div id="transcript-turns"></div>')
    const {hook} = mountHook(TranscriptTail, "#transcript")
    expect(hook.pinned).toBe(true)
    const turns = el.querySelector("#transcript-turns")
    turns.innerHTML = '<article id="turns-turn-1">one</article><article id="turns-turn-2">two</article>'
    const scrolled = []
    turns.lastElementChild.scrollIntoView = options => scrolled.push(options)
    hook.beforeUpdate()
    hook.updated()
    expect(scrolled).toEqual([{block: "start"}])
    expect(hook.pinned).toBe(false)
    expect(el.classList.contains("unpinned")).toBe(true)
    hook.beforeUpdate()
    hook.updated()
    expect(scrolled.length).toBe(1)
  } finally {
    window.history.replaceState(null, "", original)
  }
})

test("a fragment that names no drawn turn is given up on", () => {
  const el = document.querySelector("#transcript")
  const original = window.location.href
  window.history.replaceState(null, "", "#turns-gone")
  try {
    el.insertAdjacentHTML("beforeend", '<div id="transcript-turns"><article id="turns-here">here</article></div>')
    const {hook} = mountHook(TranscriptTail, "#transcript")
    expect(hook.revealed).toBe(true)
    expect(hook.pinned).toBe(true)
  } finally {
    window.history.replaceState(null, "", original)
  }
})

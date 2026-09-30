import {afterEach, beforeEach, expect, test} from "bun:test"
import {Shell, decode, loadXterm, monoFont, theme, xtermStyles} from "../js/hooks/shell.js"
import {mountHook} from "./setup.js"

// xterm.js itself is not what is under test: a stand-in with its surface.
class FakeTerminal {
  static made = []
  constructor(options) {
    this.options = options
    this.cols = 80
    this.rows = 24
    this.written = []
    this.resets = 0
    this.focused = 0
    this.disposed = false
    this.buffer = {active: {viewportY: 0, baseY: 0}}
    FakeTerminal.made.push(this)
  }
  loadAddon(addon) {
    addon.term = this
  }
  open(el) {
    this.textarea = document.createElement("textarea")
    el.appendChild(this.textarea)
  }
  onData(fn) {
    this.data = fn
  }
  onResize(fn) {
    this.resized = fn
  }
  write(bytes, done) {
    if (typeof bytes === "string") bytes = new TextEncoder().encode(bytes)
    if (bytes.length) this.written.push(new TextDecoder().decode(bytes))
    done?.()
  }
  resize(cols, rows) {
    this.resizes = [...(this.resizes || []), [cols, rows]]
    this.cols = cols
    this.rows = rows
    this.resized?.({cols, rows})
  }
  scrollToBottom() {
    this.scrolled = "bottom"
    this.buffer.active.viewportY = this.buffer.active.baseY
  }
  scrollToLine(line) {
    this.scrolled = line
    this.buffer.active.viewportY = line
  }
  reset() {
    this.resets++
    this.written = []
  }
  focus() {
    this.focused++
  }
  dispose() {
    this.disposed = true
  }
}

class FakeFit {
  fit() {
    this.fits = (this.fits || 0) + 1
    this.term.cols = 132
    this.term.rows = 43
  }
}

let observers
beforeEach(() => {
  FakeTerminal.made = []
  observers = []
  window.RavixXterm = {Terminal: FakeTerminal, FitAddon: FakeFit}
  globalThis.ResizeObserver = class {
    constructor(fn) {
      this.fn = fn
      observers.push(this)
    }
    observe() {}
    disconnect() {
      this.disconnected = true
    }
  }
  document.body.innerHTML = `
    <div id="pane-a"><div id="shell-a" data-id="a" data-label="Terminal 1" data-xterm-js="/x.js" data-xterm-css="/x.css"></div></div>
    <div id="pane-b" hidden><div id="shell-b" data-id="b" data-label="Terminal 2"></div></div>`
})

afterEach(() => {
  delete window.RavixXterm
})

const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms))
const frame = () => new Promise(resolve => requestAnimationFrame(() => resolve()))
const b64 = text => btoa(String.fromCharCode(...new TextEncoder().encode(text)))

test("a pane draws a terminal, measures it and asks to be attached at that size", async () => {
  const {hook, events} = mountHook(Shell, "#shell-a")
  await tick()
  const term = FakeTerminal.made[0]

  expect(term.textarea.getAttribute("aria-label")).toBe("Terminal 1")
  expect(term.options.scrollback).toBe(5000)
  expect(events).toEqual([{name: "shell-attach", payload: {id: "a", cols: 132, rows: 43, select: false}, target: hook.el}])
  expect(term.focused).toBe(1)
})

// RAV-88: the open request is the size the shell draws its first prompt at,
// so it is the fitted size, measured only once xterm's stylesheet applies.
test("the open request carries the fitted size, measured after xterm's stylesheet has applied", async () => {
  // Not the pane an earlier test left in front.
  sessionStorage.clear()
  const link = document.createElement("link")
  link.dataset.xterm = ""
  document.head.appendChild(link)
  try {
    const {hook, events} = mountHook(Shell, "#shell-a")
    await tick(10)
    expect(events).toEqual([])
    expect(hook.fit?.fits).toBeUndefined()

    link.dispatchEvent(new Event("load"))
    await tick(10)
    expect(hook.fit.fits).toBe(1)
    expect(events.map(e => [e.name, e.payload])).toEqual([["shell-attach", {id: "a", cols: 132, rows: 43, select: false}]])

    // The size it opened at is not sent again as a resize: the shell would
    // only redraw its prompt for it.
    FakeTerminal.made[0].resized({cols: 132, rows: 43})
    await tick(120)
    expect(events.filter(e => e.name === "shell-resize")).toEqual([])
  } finally {
    link.remove()
  }
})

test("a stylesheet that never loads, or already has, does not hold the terminal back", async () => {
  expect(await xtermStyles()).toBeUndefined()
  const link = document.createElement("link")
  link.dataset.xterm = ""
  document.head.appendChild(link)
  try {
    expect(await xtermStyles(document, 5)).toBeUndefined()
    const failed = xtermStyles()
    link.dispatchEvent(new Event("error"))
    expect(await failed).toBeUndefined()
    link.dataset.settled = ""
    expect(await xtermStyles()).toBeUndefined()
  } finally {
    link.remove()
  }
})

test("keystrokes are batched into one event, and a resize settles before it is sent", async () => {
  const {events} = mountHook(Shell, "#shell-a")
  await tick()
  const term = FakeTerminal.made[0]
  events.length = 0

  term.data("l")
  term.data("s")
  term.data("\r")
  await tick(20)
  expect(events).toEqual([{name: "shell-input", payload: {id: "a", data: "ls\r"}}])

  term.resized({cols: 100, rows: 30})
  term.resized({cols: 120, rows: 40})
  await tick(120)
  expect(events.at(-1)).toEqual({name: "shell-resize", payload: {id: "a", cols: 120, rows: 40}})
  expect(events.filter(e => e.name === "shell-resize")).toHaveLength(1)

  // Settling back where it already is sends nothing more.
  term.resized({cols: 100, rows: 30})
  term.resized({cols: 120, rows: 40})
  await tick(120)
  expect(events.filter(e => e.name === "shell-resize")).toHaveLength(1)
})

test("output is written only to its own pane, UTF-8 intact, and a reset clears it", async () => {
  const {receive} = mountHook(Shell, "#shell-a")
  // Output that arrives before xterm has loaded is kept for it.
  receive("shell:output", {id: "a", data: b64("early ")})
  await tick()
  const term = FakeTerminal.made[0]

  receive("shell:output", {id: "a", data: b64("héllo ✓")})
  receive("shell:output", {id: "b", data: b64("not mine")})
  expect(term.written.join("")).toBe("early héllo ✓")

  receive("shell:reset", {id: "b"})
  expect(term.resets).toBe(0)
  receive("shell:reset", {id: "a"})
  expect(term.resets).toBe(1)
  expect(term.written).toEqual([])
})

test("a hidden pane keeps its size until shown, then measures and takes the keyboard", async () => {
  const {hook} = mountHook(Shell, "#shell-b")
  await tick()
  const term = FakeTerminal.made[0]
  expect(hook.fit.fits).toBeUndefined()
  expect(term.focused).toBe(0)

  document.getElementById("pane-b").hidden = false
  observers[0].fn()
  expect(hook.fit.fits).toBe(1)
  expect(term.focused).toBe(1)
})

test("a pane shown after output arrived behind another tab opens at the end, not the top", async () => {
  const {hook} = mountHook(Shell, "#shell-b")
  await tick()
  const term = FakeTerminal.made[0]
  // A reload's replay lands while the pane is hidden: the buffer has
  // scrolled, but the browser would show the hidden viewport from the top.
  term.buffer.active.baseY = 30
  term.buffer.active.viewportY = 0

  document.getElementById("pane-b").hidden = false
  observers[0].fn()
  await frame()
  expect(term.scrolled).toBe("bottom")
  expect(term.buffer.active.viewportY).toBe(30)
})

// RAV-105: xterm 6 scrolls its viewport's scroll area, clamped to the height
// it last measured, and a pane just shown may not have measured it yet. The
// first scrolls then land nowhere; the pane keeps trying until one lands.
test("a scroll lost to a viewport that has not measured yet is tried again", async () => {
  const {hook, events} = mountHook(Shell, "#shell-b")
  await tick()
  const term = FakeTerminal.made[0]
  term.buffer.active.baseY = 30
  term.buffer.active.viewportY = 0
  let unmeasured = 2
  const scrollToBottom = term.scrollToBottom.bind(term)
  term.scrollToBottom = () => (unmeasured-- > 0 ? (term.scrolled = "clamped") : scrollToBottom())

  document.getElementById("pane-b").hidden = false
  observers[0].fn()
  await frame()
  expect(term.buffer.active.viewportY).toBe(0)
  // A lost scroll resizes the terminal through one row more and back, once,
  // which is what makes xterm take its viewport's height again ...
  const {cols, rows} = term
  expect(term.resizes).toEqual([[cols, rows + 1], [cols, rows]])
  await frame()
  await frame()
  expect(term.scrolled).toBe("bottom")
  expect(term.buffer.active.viewportY).toBe(30)
  expect(term.resizes).toHaveLength(2)
  expect(hook.visible).toBe(true)
  // ... and the shell is never sent the row it went through: only the size
  // the pane was fitted to when shown.
  await tick(120)
  expect(events.filter(e => e.name === "shell-resize").map(e => e.payload)).toEqual([{id: "b", cols, rows}])
})

test("a scroll that never lands gives up after a bounded number of frames", async () => {
  mountHook(Shell, "#shell-b")
  await tick()
  const term = FakeTerminal.made[0]
  term.buffer.active.baseY = 30
  let tries = 0
  term.scrollToBottom = () => tries++

  document.getElementById("pane-b").hidden = false
  observers[0].fn()
  for (let i = 0; i < 40; i++) await frame()
  expect(tries).toBe(30)
})

test("a pane hidden while scrolled back comes back on the same line", async () => {
  const {hook} = mountHook(Shell, "#shell-a")
  await tick()
  const term = FakeTerminal.made[0]
  term.buffer.active.baseY = 40
  term.buffer.active.viewportY = 12

  document.getElementById("pane-a").hidden = true
  observers[0].fn()
  term.buffer.active.viewportY = 0
  document.getElementById("pane-a").hidden = false
  observers[0].fn()
  await frame()
  expect(term.scrolled).toBe(12)

  // Following the output when hidden: it follows it again when shown.
  term.buffer.active.viewportY = 40
  document.getElementById("pane-a").hidden = true
  observers[0].fn()
  document.getElementById("pane-a").hidden = false
  observers[0].fn()
  await frame()
  expect(term.scrolled).toBe("bottom")
  expect(hook.hiddenAt).toBeNull()
})

test("a reconnect or the Reconnect button attaches again", async () => {
  const {hook, events} = mountHook(Shell, "#shell-a")
  await tick()
  events.length = 0

  hook.disconnected()
  hook.reconnected()
  hook.el.dispatchEvent(new CustomEvent("ravix:shell-reattach"))
  expect(events.map(e => [e.name, e.payload.select])).toEqual([["shell-attach", true], ["shell-attach", false]])

  // A pane that was behind another tab stays there.
  const {hook: hidden, events: behind} = mountHook(Shell, "#shell-b")
  await tick()
  behind.length = 0
  hidden.disconnected()
  hidden.reconnected()
  expect(behind.map(e => e.payload.select)).toEqual([false])
})

test("a pane remounted by a reconnect is put back in front if it was in front", async () => {
  const {hook} = mountHook(Shell, "#shell-a")
  await tick()
  hook.destroyed()

  // The page's replacement, a moment later: the same tab, a new pane.
  document.body.innerHTML = `<div><div id="shell-a" data-id="a"></div></div><div hidden><div id="shell-z" data-id="z"></div></div>`
  const {events} = mountHook(Shell, "#shell-a")
  await tick()
  expect(events.at(-1).payload.select).toBe(true)

  // Only once, and only for that tab.
  const {events: later} = mountHook(Shell, "#shell-a")
  await tick()
  expect(later.at(-1).payload.select).toBe(false)

  // A hidden pane going leaves no note; a stale note is ignored; a broken one too.
  const {hook: hidden} = mountHook(Shell, "#shell-z")
  await tick()
  hidden.destroyed()
  expect(sessionStorage.getItem("ravix.shell.front")).toBeNull()
  sessionStorage.setItem("ravix.shell.front", JSON.stringify({id: "a", at: Date.now() - 60_000}))
  const {events: stale} = mountHook(Shell, "#shell-a")
  await tick()
  expect(stale.at(-1).payload.select).toBe(false)
  sessionStorage.setItem("ravix.shell.front", "{not json")
  const {events: broken} = mountHook(Shell, "#shell-a")
  await tick()
  expect(broken.at(-1).payload.select).toBe(false)
})

test("the theme follows the page's palette", async () => {
  // happy-dom does not inherit custom properties, so they are set where read.
  const el = document.getElementById("shell-a")
  el.style.setProperty("--code-bg", "#010203")
  el.style.setProperty("--ink", "#fafafa")
  el.style.setProperty("--mono", "Plex Mono")
  mountHook(Shell, "#shell-a")
  await tick()
  const term = FakeTerminal.made[0]
  expect(term.options.theme.background).toBe("#010203")
  expect(term.options.fontFamily).toBe("Plex Mono")

  el.style.setProperty("--code-bg", "#0a0b0c")
  document.documentElement.setAttribute("data-theme", "nord")
  await tick()
  expect(term.options.theme.background).toBe("#0a0b0c")
  expect(theme(el).foreground).toBe("#fafafa")
  expect(theme(document.body).red).toBeUndefined()
})

test("closing the pane disposes the terminal and stops observing", async () => {
  const {hook} = mountHook(Shell, "#shell-a")
  await tick()
  hook.destroyed()
  expect(FakeTerminal.made[0].disposed).toBe(true)
  expect(observers[0].disconnected).toBe(true)
})

test("a pane closed before xterm arrived never draws one", async () => {
  const {hook} = mountHook(Shell, "#shell-a")
  hook.destroyed()
  await tick()
  expect(FakeTerminal.made).toHaveLength(0)
})

// A document that records what is added to its head instead of fetching it.
function fakeDocument() {
  const added = []
  return {
    added,
    querySelector: selector => added.find(el => selector === "link[data-xterm]" && el.dataset?.xterm === ""),
    createElement: () => ({dataset: {}}),
    head: {appendChild: el => added.push(el)},
  }
}

test("the bundle is loaded once, with its stylesheet, and a failed load is tried again", async () => {
  delete window.RavixXterm
  const doc = fakeDocument()
  const first = loadXterm("/assets/js/xterm.js", "/assets/js/xterm.css", doc)
  expect(loadXterm("/assets/js/xterm.js", "/assets/js/xterm.css", doc)).toBe(first)
  const [link, script] = doc.added
  expect(link.href).toBe("/assets/js/xterm.css")
  expect(script.src).toBe("/assets/js/xterm.js")

  window.RavixXterm = {Terminal: FakeTerminal, FitAddon: FakeFit}
  link.onload()
  expect(link.dataset.settled).toBe("")
  script.onload()
  expect(await first).toBe(window.RavixXterm)
  expect(await loadXterm("/other.js", null, doc)).toBe(window.RavixXterm)

  delete window.RavixXterm
  const again = fakeDocument()
  const failing = loadXterm("/missing.js", null, again)
  again.added[0].onerror()
  await expect(failing).rejects.toThrow("xterm did not load")

  // Loaded, but it did not define what it should have.
  const retry = fakeDocument()
  const empty = loadXterm("/empty.js", "/x.css", retry)
  expect(retry.added).toHaveLength(2)
  retry.added[1].onload()
  await expect(empty).rejects.toThrow("xterm did not load")
})

test("a pane whose bundle cannot load says so", async () => {
  delete window.RavixXterm
  window.happyDOM.settings.disableJavaScriptFileLoading = true
  window.happyDOM.settings.disableCSSFileLoading = true
  try {
    const {hook} = mountHook(Shell, "#shell-a")
    await tick(10)
    expect(hook.el.textContent).toContain("could not be loaded")
    expect(FakeTerminal.made).toHaveLength(0)
  } finally {
    window.happyDOM.settings.disableJavaScriptFileLoading = false
    window.happyDOM.settings.disableCSSFileLoading = false
  }
})

test("the monospace font is loaded before xterm measures it, and a failure does not block it", async () => {
  const el = document.getElementById("shell-a")
  expect(await monoFont(el)).toBeUndefined()

  el.style.setProperty("--mono", "Plex Mono")
  const asked = []
  const fonts = document.fonts
  Object.defineProperty(document, "fonts", {configurable: true, value: {load: spec => (asked.push(spec), Promise.reject(new Error("offline")))}})
  try {
    expect(await monoFont(el)).toBeUndefined()
    expect(asked).toEqual(["12px Plex Mono"])
  } finally {
    Object.defineProperty(document, "fonts", {configurable: true, value: fonts})
  }
})

test("decode is bytes, not a string", () => {
  expect(decode(b64("✓"))).toEqual(new Uint8Array([0xe2, 0x9c, 0x93]))
})

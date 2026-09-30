import {afterEach, expect, test} from "bun:test"
import {HOVER_DELAY_MS, WARM_MS, installTooltips, keysLabel, place} from "../js/tooltip"

let tips
afterEach(() => {
  tips?.stop()
  tips = null
  document.body.innerHTML = ""
})

const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
const tip = () => document.getElementById("tooltip")
const shown = () => (tip() && !tip().hidden ? tip().textContent : null)

function setup(html = `<button id="a" aria-label="Search" data-tip="Search" data-tip-kbd="Mod+K">s</button>
  <button id="b" aria-label="Close" data-tip="Close">x</button><p id="plain">text</p>`, {mac = true} = {}) {
  document.body.innerHTML = html
  tips = installTooltips(window, {mac})
  return id => document.getElementById(id)
}

const hover = el => el.dispatchEvent(new MouseEvent("mouseover", {bubbles: true}))
const leave = (el, to = document.body) => el.dispatchEvent(new MouseEvent("mouseout", {bubbles: true, relatedTarget: to}))

test("hovering a control shows its tip and shortcut after a pause, and leaving hides it", async () => {
  const $ = setup()
  hover($("a"))
  expect(shown()).toBeNull()
  await wait(HOVER_DELAY_MS + 20)
  expect(shown()).toBe("Search⌘K")
  expect(tip().querySelector("kbd").textContent).toBe("⌘K")
  expect(tip().getAttribute("role")).toBe("tooltip")
  expect($("a").getAttribute("aria-describedby")).toBe("tooltip")
  leave($("a"))
  expect(shown()).toBeNull()
  expect($("a").hasAttribute("aria-describedby")).toBe(false)
})

test("leaving before the pause ends shows nothing", async () => {
  const $ = setup()
  hover($("a"))
  leave($("a"))
  await wait(HOVER_DELAY_MS + 20)
  expect(shown()).toBeNull()
})

test("moving into the control's own icon keeps the tip", async () => {
  const $ = setup(`<button id="a" data-tip="Search" aria-label="Search"><svg id="i"></svg></button>`)
  hover($("i"))
  await wait(HOVER_DELAY_MS + 20)
  leave($("a"), $("i"))
  expect(shown()).toBe("Search")
})

test("the next control's tip shows at once while the last one's is warm", async () => {
  const $ = setup()
  hover($("a"))
  await wait(HOVER_DELAY_MS + 20)
  hover($("b"))
  expect(shown()).toBe("Close")
  leave($("b"))
  hover($("a"))
  expect(shown()).toBe("Search⌘K")
  leave($("a"))
  await wait(WARM_MS + 20)
  hover($("b"))
  expect(shown()).toBeNull()
})

test("keyboard focus shows the tip at once; blur hides it", () => {
  const $ = setup()
  $("a").focus()
  expect(shown()).toBe("Search⌘K")
  $("a").blur()
  expect(shown()).toBeNull()
})

test("focus that is not keyboard focus shows nothing", () => {
  const $ = setup()
  const matches = $("a").matches.bind($("a"))
  $("a").matches = selector => (selector === ":focus-visible" ? false : matches(selector))
  $("a").focus()
  expect(shown()).toBeNull()
})

test("a press or Escape dismisses the tip until the pointer leaves", async () => {
  const $ = setup()
  $("a").focus()
  document.dispatchEvent(new KeyboardEvent("keydown", {key: "Escape", bubbles: true}))
  expect(shown()).toBeNull()
  hover($("a"))
  await wait(HOVER_DELAY_MS + 20)
  expect(shown()).toBeNull()
  leave($("a"))
  $("a").blur()

  hover($("b"))
  await wait(HOVER_DELAY_MS + 20)
  $("b").dispatchEvent(new MouseEvent("pointerdown", {bubbles: true}))
  expect(shown()).toBeNull()
  $("b").focus()
  expect(shown()).toBeNull()
  leave($("b"))
  $("b").blur()
  $("b").focus()
  expect(shown()).toBe("Close")
})

test("a rewritten tip is followed and a removed control takes its tip with it", async () => {
  const $ = setup()
  $("a").focus()
  $("a").dataset.tip = "Show sidebar"
  await wait(0)
  expect(shown()).toBe("Show sidebar⌘K")
  $("a").remove()
  await wait(0)
  expect(shown()).toBeNull()
})

test("an empty tip, a scroll and a resize show nothing", () => {
  const $ = setup(`<button id="a" data-tip="">x</button><button id="b" data-tip="B">y</button>`)
  $("a").focus()
  expect(shown()).toBeNull()
  $("b").focus()
  window.dispatchEvent(new Event("scroll"))
  expect(shown()).toBeNull()
  $("b").blur()
  $("b").focus()
  window.dispatchEvent(new Event("resize"))
  expect(shown()).toBeNull()
})

test("hovering nothing tipped hides a tip, and stopping removes the element", () => {
  const $ = setup()
  $("a").focus()
  hover($("plain"))
  expect(shown()).toBeNull()
  tips.stop()
  tips = null
  expect(tip()).toBeNull()
})

function rect(el, r) {
  el.getBoundingClientRect = () => ({...r, right: r.left + r.width, bottom: r.top + r.height})
}

test("the tip sits under its control, over it at the bottom edge, and inside the viewport", () => {
  const anchor = document.createElement("button")
  const t = document.createElement("div")
  const win = {innerWidth: 400, innerHeight: 300}
  rect(t, {left: 0, top: 0, width: 100, height: 20})

  rect(anchor, {left: 150, top: 50, width: 20, height: 20})
  place(t, anchor, win)
  expect([t.style.left, t.style.top, t.dataset.side]).toEqual(["110px", "76px", "below"])

  rect(anchor, {left: 380, top: 270, width: 20, height: 20})
  place(t, anchor, win)
  expect([t.style.left, t.style.top, t.dataset.side]).toEqual(["296px", "244px", "above"])

  rect(anchor, {left: 0, top: 50, width: 20, height: 20})
  place(t, anchor, win)
  expect(t.style.left).toBe("4px")
})

test("a shortcut reads ⌘ on a Mac and Ctrl+ elsewhere", () => {
  expect(keysLabel("Mod+K", true)).toBe("⌘K")
  expect(keysLabel("Mod+K", false)).toBe("Ctrl+K")
  expect(keysLabel("F2", false)).toBe("F2")
  const $ = setup(undefined, {mac: false})
  $("a").focus()
  expect(shown()).toBe("SearchCtrl+K")
})

test("the tip describes its control unless it only repeats the name, and keeps other descriptions", () => {
  const $ = setup(`<button id="a" aria-label="Close" data-tip="Close">x</button>
    <button id="b" aria-label="More for this turn" data-tip="More" aria-describedby="hint">y</button>`)
  $("a").focus()
  expect(shown()).toBe("Close")
  expect($("a").hasAttribute("aria-describedby")).toBe(false)
  $("b").focus()
  expect($("b").getAttribute("aria-describedby")).toBe("hint tooltip")
  $("b").blur()
  expect($("b").getAttribute("aria-describedby")).toBe("hint")
})

test("focus after pointer input shows no tip", () => {
  const $ = setup()
  document.documentElement.dataset.input = "pointer"
  try {
    $("a").focus()
    expect(shown()).toBeNull()
  } finally {
    delete document.documentElement.dataset.input
  }
})

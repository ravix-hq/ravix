import {beforeEach, expect, test} from "bun:test"
import {GAP, MARGIN, NARROW, SharePopover, place} from "../js/hooks/share_popover.js"
import {dimensions, key, mountHook} from "./setup.js"

// happy-dom lays nothing out, so each test says where the button is.
const rect = (el, {left, top, width, height}) => {
  el.getBoundingClientRect = () => ({left, top, width, height, right: left + width, bottom: top + height})
}

let closes, copies
beforeEach(() => {
  window.innerWidth = 1440
  window.innerHeight = 900
  document.body.innerHTML = `
    <button id="track-share-button">Share</button>
    <button id="elsewhere">Elsewhere</button>
    <div id="track-share-dialog" class="share-layer" data-anchor="track-share-button">
      <div class="share-popover" role="dialog">
        <div class="dialog-head"><button class="x" aria-label="Close">x</button></div>
        <input id="share-person" type="text">
        <select id="scope"><option>Everyone</option></select>
        <div id="share-link"><button type="button">Copy link</button></div>
      </div>
    </div>`
  closes = 0
  copies = 0
  document.querySelector(".x").addEventListener("click", () => closes++)
  document.querySelector("#share-link button").addEventListener("click", () => copies++)
  dimensions(document.querySelector(".share-popover"), {offsetWidth: 440})
  rect(document.querySelector("#track-share-button"), {left: 1100, top: 12, width: 80, height: 32})
})

const $ = sel => document.querySelector(sel)

test("hangs under Share with the right edges aligned", () => {
  const {hook} = mountHook(SharePopover, "#track-share-dialog")
  expect(hook.el.style.top).toBe(`${44 + GAP}px`)
  expect(hook.el.style.left).toBe(`${1180 - 440}px`)
  expect(hook.el.hasAttribute("data-placed")).toBe(true)
})

test("stays inside the viewport when Share is near its left edge", () => {
  const anchor = $("#track-share-button")
  expect(place(anchor, {offsetWidth: 440}, {width: 1440}).left).toBe(740)
  rect(anchor, {left: 10, top: 12, width: 80, height: 32})
  expect(place(anchor, {offsetWidth: 440}, {width: 1440}).left).toBe(MARGIN)
  rect(anchor, {left: 1400, top: 12, width: 80, height: 32})
  expect(place(anchor, {offsetWidth: 440}, {width: 1440}).left).toBe(1440 - 440 - MARGIN)
})

test("follows the button when the window resizes, and on a narrow one leaves it to the stylesheet", () => {
  const {hook} = mountHook(SharePopover, "#track-share-dialog")
  rect($("#track-share-button"), {left: 900, top: 12, width: 80, height: 32})
  window.dispatchEvent(new Event("resize"))
  expect(hook.el.style.left).toBe(`${980 - 440}px`)

  window.innerWidth = NARROW - 1
  window.dispatchEvent(new Event("resize"))
  expect(hook.el.style.top).toBe("")
  expect(hook.el.style.left).toBe("")
  expect(hook.el.hasAttribute("data-placed")).toBe(false)

  window.innerWidth = 1440
  hook.updated()
  expect(hook.el.hasAttribute("data-placed")).toBe(true)
})

test("a second click on Share closes it once, and does not reach the page", () => {
  mountHook(SharePopover, "#track-share-dialog")
  let reached = 0
  window.addEventListener("click", () => reached++)
  const event = new MouseEvent("click", {bubbles: true, cancelable: true})
  $("#track-share-button").dispatchEvent(event)
  expect(closes).toBe(1)
  expect(event.defaultPrevented).toBe(true)
  // Close's own click is the only one that bubbles up to LiveView.
  expect(reached).toBe(1)

  // Once hidden (Escape, or a click outside), Share opens it as usual.
  $("#track-share-dialog").hidden = true
  $("#track-share-button").click()
  expect(closes).toBe(1)
  expect(reached).toBe(2)
})

test("C copies the link from anywhere but a field", () => {
  mountHook(SharePopover, "#track-share-dialog")
  const pressed = key($(".x"), "c")
  expect(copies).toBe(1)
  expect(pressed.defaultPrevented).toBe(true)
  key($(".x"), "C")
  expect(copies).toBe(2)

  for (const [el, options] of [
    [$("#share-person"), {}],
    [$("#scope"), {}],
    [$(".x"), {ctrlKey: true}],
    [$(".x"), {metaKey: true}],
    [$(".x"), {altKey: true}],
  ]) {
    expect(key(el, "c", options).defaultPrevented).toBe(false)
  }
  key($(".x"), "x")
  expect(copies).toBe(2)
})

test("stops listening once the server removes it", () => {
  const {hook} = mountHook(SharePopover, "#track-share-dialog")
  hook.destroyed()
  hook.el.style.left = ""
  window.dispatchEvent(new Event("resize"))
  expect(hook.el.style.left).toBe("")
  $("#track-share-button").click()
  expect(closes).toBe(0)
})

test("without its button it is not placed", () => {
  $("#track-share-button").remove()
  const {hook} = mountHook(SharePopover, "#track-share-dialog")
  expect(hook.el.hasAttribute("data-placed")).toBe(false)
})

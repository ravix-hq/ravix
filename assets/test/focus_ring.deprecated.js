import {afterEach, expect, test} from "bun:test"
import {trackInputModality} from "../js/focus_ring"

let modality
afterEach(() => {
  modality?.stop()
  modality = null
  document.body.innerHTML = ""
})

const input = () => document.documentElement.dataset.input
const press = (key, target = document.body, options = {}) =>
  target.dispatchEvent(new KeyboardEvent("keydown", {key, bubbles: true, ...options}))

test("a pointer press marks pointer input, and navigation keys mark the keyboard", () => {
  document.body.innerHTML = `<button id="b">b</button>`
  modality = trackInputModality(window)
  expect(input()).toBeUndefined()
  document.getElementById("b").dispatchEvent(new MouseEvent("pointerdown", {bubbles: true}))
  expect(input()).toBe("pointer")
  press("Tab")
  expect(input()).toBe("keyboard")
  document.body.dispatchEvent(new MouseEvent("pointerdown", {bubbles: true}))
  press("ArrowDown")
  expect(input()).toBe("keyboard")
})

test("Escape, typing and shortcuts after a click keep it pointer input", () => {
  document.body.innerHTML = `<textarea id="t"></textarea><input id="i"><button id="b">b</button>`
  modality = trackInputModality(window)
  document.body.dispatchEvent(new MouseEvent("pointerdown", {bubbles: true}))
  press("Escape")
  press("a", document.getElementById("t"))
  press("Enter", document.getElementById("t"))
  press(" ", document.getElementById("i"))
  press("Tab", document.body, {ctrlKey: true})
  press("k", document.body, {metaKey: true})
  expect(input()).toBe("pointer")
  // Enter on a button acts on it from the keyboard.
  press("Enter", document.getElementById("b"))
  expect(input()).toBe("keyboard")
})

test("stopping forgets the input and listens no more", () => {
  modality = trackInputModality(window)
  press("Tab")
  expect(input()).toBe("keyboard")
  modality.stop()
  modality = null
  expect(input()).toBeUndefined()
  press("Tab")
  expect(input()).toBeUndefined()
})

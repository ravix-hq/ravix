import {afterEach, beforeEach, expect, test} from "bun:test"
import {HeaderFit, LABEL_GAP, compact} from "../js/hooks/header_fit.js"
import {dimensions, mountHook} from "./setup.js"

// happy-dom lays nothing out, so each test says how wide things are.
let observers
const native = globalThis.ResizeObserver
beforeEach(() => {
  observers = []
  globalThis.ResizeObserver = class {
    constructor(fn) {
      this.fn = fn
      this.targets = []
      observers.push(this)
    }
    observe(el) {
      this.targets.push(el)
    }
    disconnect() {
      this.disconnected = true
    }
  }
  document.body.innerHTML = `<header id="h">
    <strong class="track-title-crumb">Pull Latest Main</strong>
    <span class="spacer"></span>
    <button class="chip track-plan-chip"><span id="plan" data-fit-label>Plan: Small fixes</span></button>
    <span class="chip"><span id="state" data-fit-label>Asleep</span></span>
  </header>`
})

afterEach(() => {
  globalThis.ResizeObserver = native
})

const $ = sel => document.querySelector(sel)
const widths = (sel, scrollWidth, clientWidth) => dimensions($(sel), {scrollWidth, clientWidth})
const whole = () => {
  widths("#plan", 120, 120)
  widths("#state", 40, 40)
}

test("whole labels leave the header as it is; a cut one makes it compact", () => {
  whole()
  const {hook} = mountHook(HeaderFit, "#h")
  expect(hook.el.hasAttribute("data-compact")).toBe(false)
  expect(observers[0].targets).toEqual([hook.el, $(".spacer")])

  widths("#state", 40, 12)
  observers[0].fn()
  expect(hook.el.hasAttribute("data-compact")).toBe(true)
})

test("compact holds until the spacer fits every label", () => {
  widths("#plan", 120, 0)
  widths("#state", 40, 0)
  const header = $("#h")
  header.setAttribute("data-compact", "")
  const needed = 120 + 40 + 2 * LABEL_GAP

  dimensions($(".spacer"), {clientWidth: needed - 1})
  expect(compact(header)).toBe(true)
  dimensions($(".spacer"), {clientWidth: needed})
  expect(compact(header)).toBe(false)
})

test("a patch is measured again, and a header without labels is never compact", () => {
  whole()
  const {hook} = mountHook(HeaderFit, "#h")
  widths("#plan", 120, 60)
  hook.updated()
  expect(hook.el.hasAttribute("data-compact")).toBe(true)
  hook.destroyed()
  expect(observers[0].disconnected).toBe(true)

  document.body.innerHTML = `<header id="bare" data-compact></header>`
  expect(compact($("#bare"))).toBe(false)
  mountHook(HeaderFit, "#bare")
  expect($("#bare").hasAttribute("data-compact")).toBe(false)
  expect(observers[1].targets).toEqual([$("#bare")])
})

test("a header whose controls run past its end is compact, and stays so", () => {
  whole()
  const header = $("#h")
  dimensions(header, {scrollWidth: 900, clientWidth: 800})
  expect(compact(header)).toBe(true)
  header.setAttribute("data-compact", "")
  dimensions($(".spacer"), {clientWidth: 1000})
  expect(compact(header)).toBe(true)
  dimensions(header, {scrollWidth: 800, clientWidth: 800})
  expect(compact(header)).toBe(false)
})

test("with no spacer there is no room to give back", () => {
  document.body.innerHTML = `<header id="h" data-compact><span data-fit-label id="l">Own machine</span></header>`
  widths("#l", 80, 0)
  expect(compact($("#h"))).toBe(true)
})

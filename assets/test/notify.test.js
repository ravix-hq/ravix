import {afterEach, beforeEach, expect, test} from "bun:test"
import {NOTIFY_KEY, Notify} from "../js/hooks/notify.js"
import {dimensions, mountHook} from "./setup.js"

// The browser's Notification API, as far as the hook touches it: a static
// permission, a request that answers with whatever the test chose, and a
// record of what was shown.
class FakeNotification {
  static permission = "default"
  static answer = "granted"
  static asked = 0
  static shown = []

  static requestPermission() {
    FakeNotification.asked += 1
    FakeNotification.permission = FakeNotification.answer
    return Promise.resolve(FakeNotification.permission)
  }

  constructor(title, options) {
    this.title = title
    this.options = options
    this.closed = false
    FakeNotification.shown.push(this)
  }

  close() {
    this.closed = true
  }
}

const markup = `<div class="notify"><button data-notify-toggle aria-pressed="false"><span data-notify-dot></span>
  <span class="col"><small>Desktop notifications</small><span data-notify-state></span></span></button></div>`

function mount() {
  document.body.innerHTML = markup
  return mountHook(Notify, ".notify")
}

function label(hook) {
  return hook.el.querySelector("[data-notify-state]").textContent
}

function button(hook) {
  return hook.el.querySelector("[data-notify-toggle]")
}

const finished = {id: "t1", title: "Fix the build", project: "Ravix", status: "ready"}
const failed = {id: "t2", title: "Rename things", project: null, status: "failed"}

beforeEach(() => {
  FakeNotification.permission = "default"
  FakeNotification.answer = "granted"
  FakeNotification.asked = 0
  FakeNotification.shown = []
  globalThis.Notification = FakeNotification
  // Looking somewhere else, unless a test says otherwise.
  dimensions(document, {hidden: true, hasFocus: () => false})
})

afterEach(() => {
  delete globalThis.Notification
  delete document.hidden
  delete document.hasFocus
})

test("off until asked, and the click is what asks the browser", async () => {
  const {hook} = mount()
  expect(label(hook)).toBe("Off")
  expect(button(hook).getAttribute("aria-pressed")).toBe("false")
  expect(FakeNotification.asked).toBe(0)

  button(hook).click()
  // The click handler drops the promise; the browser's answer is one
  // microtask away and the hook's reaction one more.
  await Promise.resolve()
  await Promise.resolve()
  expect(FakeNotification.asked).toBe(1)
  expect(label(hook)).toBe("On")
  expect(button(hook).getAttribute("aria-pressed")).toBe("true")
  expect(hook.el.classList.contains("on")).toBe(true)
  expect(localStorage.getItem(NOTIFY_KEY)).toBe("on")

  // Off again is the person's choice alone; the browser is not asked.
  await hook.toggle()
  expect(FakeNotification.asked).toBe(1)
  expect(label(hook)).toBe("Off")
  expect(localStorage.getItem(NOTIFY_KEY)).toBe("off")
})

test("a saved yes still needs the browser's, and a denial is said rather than asked again", async () => {
  localStorage.setItem(NOTIFY_KEY, "on")
  const {hook} = mount()
  // The preference outlived a permission the browser reset.
  expect(label(hook)).toBe("Off")

  FakeNotification.answer = "denied"
  await hook.toggle()
  expect(label(hook)).toBe("Blocked in this browser")
  expect(button(hook).disabled).toBe(true)
  expect(hook.el.classList.contains("blocked")).toBe(true)
  expect(localStorage.getItem(NOTIFY_KEY)).toBe("off")

  await hook.toggle()
  expect(FakeNotification.asked).toBe(1)
})

test("a browser without the API gets a disabled button and no errors", async () => {
  delete globalThis.Notification
  const {hook, receive} = mount()
  expect(label(hook)).toBe("Not available in this browser")
  expect(button(hook).disabled).toBe(true)
  await hook.toggle()
  receive("notify", {tracks: [finished]})
  expect(label(hook)).toBe("Not available in this browser")
})

test("news is shown only when on, allowed and looked away from, once per track", async () => {
  FakeNotification.permission = "granted"
  localStorage.setItem(NOTIFY_KEY, "on")
  const {hook, events, receive} = mount()
  expect(label(hook)).toBe("On")

  // Looking right at it: the badge is already saying so.
  dimensions(document, {hidden: false, hasFocus: () => true})
  receive("notify", {tracks: [finished]})
  expect(FakeNotification.shown).toHaveLength(0)

  // A visible tab in a window behind another application counts as away.
  dimensions(document, {hidden: false, hasFocus: () => false})
  receive("notify", {tracks: [finished, failed]})
  expect(FakeNotification.shown.map(n => n.title)).toEqual(["Fix the build", "Rename things"])
  expect(FakeNotification.shown[0].options).toEqual({body: "The agent finished in Ravix.", tag: "ravix-track-t1"})
  expect(FakeNotification.shown[1].options.body).toBe("The agent hit a problem.")

  // Clicking one asks the page to open the track, and closes itself.
  let focused = 0
  dimensions(window, {focus: () => (focused += 1)})
  FakeNotification.shown[0].onclick()
  expect(focused).toBe(1)
  expect(events).toEqual([{name: "open-notice", payload: {track: "t1"}}])
  expect(FakeNotification.shown[0].closed).toBe(true)

  // Off means off, whatever arrives, and an empty event is nothing.
  await hook.toggle()
  receive("notify", {tracks: [finished]})
  receive("notify", {})
  expect(FakeNotification.shown).toHaveLength(2)
})

test("a browser that refuses to construct one is left alone", () => {
  FakeNotification.permission = "granted"
  localStorage.setItem(NOTIFY_KEY, "on")
  const {hook, receive} = mount()
  globalThis.Notification = class extends FakeNotification {
    constructor() {
      super()
      throw new TypeError("Illegal constructor")
    }
  }
  receive("notify", {tracks: [finished]})
  expect(label(hook)).toBe("On")
})

test("a server patch that redraws the label gets the state back", () => {
  FakeNotification.permission = "granted"
  localStorage.setItem(NOTIFY_KEY, "on")
  const {hook} = mount()
  hook.el.querySelector("[data-notify-state]").textContent = ""
  hook.updated()
  expect(label(hook)).toBe("On")
})

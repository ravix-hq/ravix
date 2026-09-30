import {beforeEach, expect, mock, test} from "bun:test"
import {PreviewFrame} from "../js/hooks/preview_frame.js"
import {mountHook} from "./setup.js"

const origin = "http://t-abc--p5173.preview.localhost:5183"
let frameWindow

beforeEach(() => {
  document.body.innerHTML = `<div id="preview-view" data-origin="${origin}">
    <div class="preview-bar">
      <button type="button" data-preview-nav="back">Back</button>
      <button type="button" data-preview-nav="forward">Forward</button>
      <button type="button" data-preview-nav="reload" disabled>Reload</button>
      <form id="preview-location-form" data-preview-go><input id="preview-location" value="/"></form>
    </div>
    <iframe id="preview-frame" title="Track preview"></iframe>
  </div>`
  frameWindow = {postMessage: mock(() => {})}
  Object.defineProperty(document.querySelector("iframe"), "contentWindow", {
    configurable: true,
    get: () => frameWindow,
  })
})

function report(data, {from = origin, source = frameWindow} = {}) {
  window.dispatchEvent(new MessageEvent("message", {data, origin: from, source}))
}

function submit(hook, value) {
  hook.el.querySelector("#preview-location").value = value
  const form = hook.el.querySelector("form")
  form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
}

test("the bar follows the frame's reported location and says once that it is up", () => {
  const {hook, events} = mountHook(PreviewFrame, "#preview-view")
  report({source: "ravix-preview", type: "location", state: "ok", path: "/docs?x=1#top"})
  report({source: "ravix-preview", type: "location", state: "ok", path: "/docs/next"})

  expect(hook.el.querySelector("#preview-location").value).toBe("/docs/next")
  expect(events).toEqual([{name: "preview-frame", payload: {state: "ok"}}])
})

test("an unreachable frame is reported with its port, for the empty state", () => {
  const {events} = mountHook(PreviewFrame, "#preview-view")
  report({source: "ravix-preview", type: "location", state: "unreachable", port: 5173, path: "/"})
  expect(events).toEqual([{name: "preview-frame", payload: {state: "unreachable", port: 5173}}])
})

test("messages from another origin, another window, or not the bridge are ignored", () => {
  const {hook, events} = mountHook(PreviewFrame, "#preview-view")
  const message = {source: "ravix-preview", type: "location", state: "unreachable", path: "/evil"}

  report(message, {from: "http://evil.test"})
  report(message, {source: {}})
  report({...message, source: "someone-else"})
  report(null)

  expect(events).toEqual([])
  expect(hook.el.querySelector("#preview-location").value).toBe("/")
})

test("back, forward and reload are asked of the frame, on its origin only", () => {
  const {hook} = mountHook(PreviewFrame, "#preview-view")
  const [back, forward, reload] = hook.el.querySelectorAll("[data-preview-nav]")

  back.click()
  forward.click()
  reload.click()

  expect(frameWindow.postMessage.mock.calls).toEqual([
    [{source: "ravix", type: "back"}, origin],
    [{source: "ravix", type: "forward"}, origin],
  ])
})

test("the path box navigates the frame to a path on its own origin", () => {
  const {hook} = mountHook(PreviewFrame, "#preview-view")
  const input = hook.el.querySelector("#preview-location")
  input.focus()
  submit(hook, "/typed")
  expect(document.activeElement).not.toBe(input)
  report({source: "ravix-preview", type: "location", state: "ok", path: "/typed"})
  expect(input.value).toBe("/typed")
  frameWindow.postMessage.mockClear()

  submit(hook, "about?tab=2")
  submit(hook, "  ")
  submit(hook, "//evil.test/steal")
  submit(hook, "/%zz")

  expect(frameWindow.postMessage.mock.calls).toEqual([
    [{source: "ravix", type: "go", path: "/about?tab=2"}, origin],
    [{source: "ravix", type: "go", path: "/"}, origin],
    [{source: "ravix", type: "go", path: "/%zz"}, origin],
  ])
})

test("a new port resets the bar, and nothing is sent without a frame", () => {
  const {hook, events} = mountHook(PreviewFrame, "#preview-view")
  report({source: "ravix-preview", type: "location", state: "ok", path: "/deep"})

  hook.el.dataset.origin = "http://t-abc--p3000.preview.localhost:5183"
  hook.updated()
  expect(hook.el.querySelector("#preview-location").value).toBe("/")

  // Same origin again: nothing to reset, and the reported state starts over.
  hook.el.querySelector("#preview-location").value = "/kept"
  hook.updated()
  expect(hook.el.querySelector("#preview-location").value).toBe("/kept")
  expect(events.length).toBe(1)

  hook.el.querySelector("iframe").remove()
  hook.el.querySelector("[data-preview-nav]").click()
  expect(frameWindow.postMessage).not.toHaveBeenCalled()

  hook.destroyed()
  report({source: "ravix-preview", type: "location", state: "unreachable", path: "/"})
  expect(events.length).toBe(1)
})

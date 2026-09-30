import {expect, test} from "bun:test"
import {SubmitOnEnter} from "../js/hooks/submit_on_enter.js"
import {mountHook} from "./setup.js"

function render(disabled = false) {
  document.body.innerHTML = `<form id="form">
      <textarea id="prompt">Fix the flaky test</textarea>
      <button type="button" id="advanced">Advanced</button>
      <button id="create" ${disabled ? "disabled" : ""}>Create track</button>
    </form>`
  const form = document.querySelector("#form")
  const submits = []
  form.addEventListener("submit", e => {
    e.preventDefault()
    submits.push(e.submitter?.id)
  })
  mountHook(SubmitOnEnter, "#prompt")
  return {el: document.querySelector("#prompt"), submits}
}

function press(el, init) {
  const event = new KeyboardEvent("keydown", {key: "Enter", bubbles: true, cancelable: true, ...init})
  el.dispatchEvent(event)
  return event
}

test("Enter submits the form through its create button", () => {
  const {el, submits} = render()
  const event = press(el)
  expect(event.defaultPrevented).toBe(true)
  expect(submits).toEqual(["create"])
})

test("Shift+Enter and an IME composition keep their Enter", () => {
  const {el, submits} = render()
  expect(press(el, {shiftKey: true}).defaultPrevented).toBe(false)
  expect(press(el, {isComposing: true}).defaultPrevented).toBe(false)
  expect(submits).toEqual([])
})

test("Enter does nothing while the create button is disabled", () => {
  const {el, submits} = render(true)
  expect(press(el).defaultPrevented).toBe(true)
  expect(submits).toEqual([])
})

test("other keys pass through", () => {
  const {el, submits} = render()
  const event = new KeyboardEvent("keydown", {key: "a", bubbles: true, cancelable: true})
  el.dispatchEvent(event)
  expect(event.defaultPrevented).toBe(false)
  expect(submits).toEqual([])
})

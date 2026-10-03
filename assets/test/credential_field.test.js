import {expect, test} from "bun:test"
import {CredentialField} from "../js/hooks/credential_field.js"
import {mountHook} from "./setup.js"

function render(state = "idle", {disabled = "false", invalid = "false"} = {}) {
  document.body.innerHTML = `<form id="credential-form">
      <input type="password" id="credential-value" data-state="${state}" data-disabled="${disabled}" data-invalid="${invalid}">
    </form>`
  const {hook} = mountHook(CredentialField, "#credential-value")
  return {hook, el: document.querySelector("#credential-value")}
}

// What a patch does to an ignored input: only its data attributes change.
function patch(el, hook, data) {
  for (const [key, value] of Object.entries(data)) el.dataset[key] = value
  hook.updated()
}

test("the paste survives the attempt and is cleared once it succeeds", () => {
  const {hook, el} = render()
  el.value = "sk-ant-oat01-private"
  patch(el, hook, {state: "connecting", disabled: "true"})
  expect(el.value).toBe("sk-ant-oat01-private")
  expect(el.disabled).toBe(true)
  patch(el, hook, {state: "idle", disabled: "false"})
  expect(el.value).toBe("")
  expect(el.disabled).toBe(false)
})

test("a refusal keeps the paste beside its error, and resetting the form clears it", () => {
  const {hook, el} = render()
  el.value = "sk-ant-WRONG"
  patch(el, hook, {state: "connecting", disabled: "true"})
  patch(el, hook, {state: "refused", disabled: "false", invalid: "true"})
  expect(el.value).toBe("sk-ant-WRONG")
  expect(el.getAttribute("aria-invalid")).toBe("true")
  // Another way to pay: a fresh form.
  patch(el, hook, {state: "idle", invalid: "false"})
  expect(el.value).toBe("")
  expect(el.hasAttribute("aria-invalid")).toBe(false)
})

test("a patch that is not about the attempt leaves the paste alone", () => {
  const {hook, el} = render()
  el.value = "typed so far"
  patch(el, hook, {state: "idle", disabled: "true"})
  patch(el, hook, {state: "idle", disabled: "false"})
  expect(el.value).toBe("typed so far")
})

test("mounting applies what the server rendered", () => {
  const {el} = render("refused", {disabled: "true", invalid: "true"})
  expect(el.disabled).toBe(true)
  expect(el.getAttribute("aria-invalid")).toBe("true")
})

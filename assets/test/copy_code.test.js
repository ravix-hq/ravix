import {beforeEach, afterEach, expect, mock, test} from "bun:test"
import {CopyCode} from "../js/hooks/copy_code.js"
import {mountHook} from "./setup.js"

let clipboard
beforeEach(() => {
  clipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard")
  document.body.innerHTML = `<div id="example"><div><span role="status"></span>
    <button type="button" aria-label="Copy example">Copy</button></div>
    <pre><code>&lt;literal&gt;\n  "quoted" &amp; exact</code></pre></div>`
})
afterEach(() => {
  if (clipboard) Object.defineProperty(navigator, "clipboard", clipboard)
  else delete navigator.clipboard
})

function setup(writeText) {
  Object.defineProperty(navigator, "clipboard", {configurable: true, value: {writeText}})
  const {hook} = mountHook(CopyCode, "#example")
  return {hook, button: hook.el.querySelector("button"), status: hook.el.querySelector('[role="status"]')}
}

test("copy preserves literal multiline text and announces success", async () => {
  const write = mock(async () => {})
  const {button, status} = setup(write)
  button.click()
  expect(button.disabled).toBe(true)
  await Promise.resolve()
  expect(write).toHaveBeenCalledWith('<literal>\n  "quoted" & exact')
  expect(status.textContent).toBe("Copied")
  expect(button.disabled).toBe(false)
})

test("denied or unavailable clipboard explains failure and allows retry", async () => {
  const {button, status} = setup(async () => {throw new Error("denied")})
  button.click()
  await Promise.resolve()
  expect(status.textContent).toBe("Copy failed. Select and copy the code.")
  expect(button.disabled).toBe(false)
  Object.defineProperty(navigator, "clipboard", {configurable: true, value: undefined})
  button.click()
  await Promise.resolve()
  expect(status.textContent).toBe("Copy failed. Select and copy the code.")
  Object.defineProperty(navigator, "clipboard", {configurable: true, value: {writeText: async () => {}}})
  button.click()
  await Promise.resolve()
  expect(status.textContent).toBe("Copied")
})

test("pending writes cannot duplicate and closing Help removes the listener", async () => {
  let finish
  const write = mock(() => new Promise(resolve => {finish = resolve}))
  const {hook, button, status} = setup(write)
  button.click()
  button.dispatchEvent(new MouseEvent("click"))
  expect(write).toHaveBeenCalledTimes(1)
  expect(status.textContent).toBe("Copying…")
  hook.destroyed()
  finish()
  await Promise.resolve()
  expect(status.textContent).toBe("Copying…")
  button.disabled = false
  button.click()
  expect(write).toHaveBeenCalledTimes(1)
})

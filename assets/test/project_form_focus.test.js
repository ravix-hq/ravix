import {expect, test} from "bun:test"
import {ProjectFormFocus} from "../js/hooks/project_form_focus.js"
import {mountHook} from "./setup.js"

for (const field of ["repository", "name"]) {
  test(`dialog initially focuses ${field} and never schedules another focus`, async () => {
    document.body.innerHTML = `<button id="close">Close</button>
      <div id="form" data-focus="#${field}"><input id="repository"><input id="name"></div>`
    document.querySelector("#close").focus()
    mountHook(ProjectFormFocus, "#form")
    expect(document.activeElement.id).toBe(field)
    const other = document.querySelector(field === "name" ? "#repository" : "#name")
    other.focus()
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
    expect(document.activeElement).toBe(other)
  })
}

test("mounting preserves a field already chosen, including typed text", () => {
  document.body.innerHTML = `<div id="form" data-focus="#repository"><input id="repository"><input id="name" value="Kept"></div>`
  const name = document.querySelector("#name")
  name.focus()
  mountHook(ProjectFormFocus, "#form")
  expect(document.activeElement).toBe(name)
  expect(name.value).toBe("Kept")
})

test("a missing target does not move focus outside the form", () => {
  document.body.innerHTML = `<button id="close">Close</button><div id="form" data-focus="#absent"></div>`
  const close = document.querySelector("#close")
  close.focus()
  mountHook(ProjectFormFocus, "#form")
  expect(document.activeElement).toBe(close)
})

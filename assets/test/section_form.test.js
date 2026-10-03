import {expect, test} from "bun:test"
import {SectionForm} from "../js/hooks/section_form.js"
import {mountHook} from "./setup.js"

const frame = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))

function mount() {
  document.body.innerHTML = `<form id="new-section-form">
      <input id="section-name" name="section[name]" value="">
      <button id="create">Create section</button>
    </form>`
  return mountHook(SectionForm, "#new-section-form")
}

test("a created section empties the field and puts the focus back in it a frame later", async () => {
  const {receive} = mount()
  const name = document.querySelector("#section-name")
  const create = document.querySelector("#create")
  name.value = "Ravioli"
  create.focus()
  receive("section-created", {id: "s1"})
  expect(name.value).toBe("")
  // Emptied at once; the focus moves only after LiveView has given it back
  // to the button that was clicked, which it does before the next frame.
  expect(document.activeElement).toBe(create)
  await frame()
  expect(document.activeElement).toBe(name)
})

test("mounting alone leaves what was typed and where the focus was", async () => {
  const {events} = mount()
  const name = document.querySelector("#section-name")
  name.value = "Half typed"
  const create = document.querySelector("#create")
  create.focus()
  await frame()
  expect(name.value).toBe("Half typed")
  expect(document.activeElement).toBe(create)
  expect(events).toEqual([])
})

test("a form whose field is gone resets without throwing", async () => {
  const {receive} = mount()
  document.querySelector("#section-name").remove()
  expect(() => receive("section-created", {id: "s1"})).not.toThrow()
  await frame()
  expect(document.activeElement).toBe(document.body)
})

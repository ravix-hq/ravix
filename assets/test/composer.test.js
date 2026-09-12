import {beforeEach, expect, test} from "bun:test"
import {Composer, accept, rejectionMessage} from "../js/hooks/composer.js"
import {dimensions, key, mountHook} from "./setup.js"

beforeEach(() => {
  document.body.innerHTML = `<form><div data-composer-box><div data-composer-note hidden></div>
    <textarea data-draft-key="track:a" data-typing-event="typing"></textarea><input type="file" multiple>
    <button>Send</button></div></form>`
})

const image = name => new File(["pixels"], name, {type: "image/png"})

test("image admission checks format, byte and count limits with actionable errors", () => {
  const tooLarge = {name: "large.png", type: "image/png", size: 8 * 1024 * 1024 + 1}
  const result = accept([image("ok.png"), new File(["x"], "file.pdf"), tooLarge, image("extra.png")], 5)
  expect(result.accepted.map(f => f.name)).toEqual(["ok.png"])
  expect(rejectionMessage(result.rejected)).toContain("file.pdf: only PNG")
  expect(rejectionMessage(result.rejected)).toContain("large.png: larger than 8 MB")
  expect(rejectionMessage(result.rejected)).toContain("extra.png: 6 images at a time")
  expect(rejectionMessage([])).toBeNull()
  expect(rejectionMessage([{name:"a",why:"type"},{name:"b",why:"type"}])).toContain("a and b")
  expect(accept([{type:"image/jpeg",size:8*1024*1024}], 0).accepted).toHaveLength(1)
})

test("drafts survive submit and are cleared only after server acknowledgement", () => {
  localStorage.setItem("ravix.draft.track:a", "Saved draft")
  const {hook, receive} = mountHook(Composer, "textarea")
  expect(hook.el.value).toBe("Saved draft")
  const submits = []
  hook.el.form.addEventListener("submit", e => {e.preventDefault(); submits.push(true)})
  key(hook.el, "Enter")
  expect(submits).toHaveLength(1)
  expect(localStorage.getItem("ravix.draft.track:a")).toBe("Saved draft")
  expect(hook.el.value).toBe("Saved draft")
  receive("composer:clear")
  expect(hook.el.value).toBe("")
  expect(localStorage.getItem("ravix.draft.track:a")).toBeNull()
  expect(hook.el.dataset.dirty).toBeUndefined()
})

test("shift-enter and IME composition do not submit; empty or disabled composers cannot send", () => {
  const {hook} = mountHook(Composer, "textarea")
  let submits = 0
  hook.el.form.addEventListener("submit", e => {e.preventDefault(); submits++})
  key(hook.el, "Enter")
  hook.el.value = "Text"
  expect(key(hook.el, "Enter", {shiftKey:true}).defaultPrevented).toBe(false)
  key(hook.el, "Enter", {isComposing:true})
  hook.el.disabled = true
  key(hook.el, "Enter")
  expect(submits).toBe(0)
})

test("typing saves and grows the draft while throttling presence events", () => {
  const {hook, events, receive} = mountHook(Composer, "textarea")
  dimensions(hook.el, {scrollHeight:400})
  hook.el.value = "Hello"
  hook.el.dispatchEvent(new Event("input"))
  hook.el.dispatchEvent(new Event("input"))
  expect(hook.el.style.height).toBe("260px")
  expect(events).toEqual([{name:"typing",payload:{}}])
  expect(localStorage.getItem("ravix.draft.track:a")).toBe("Hello")
  receive("composer:insert", {text:"Starter prompt"})
  expect(hook.el.value).toBe("Starter prompt")
  expect(document.activeElement).toBe(hook.el)
  key(hook.el, "Escape")
  expect(localStorage.getItem("ravix.draft.track:a")).toBeNull()
  hook.updated()
  hook.el.value = ""
  hook.el.dispatchEvent(new Event("input"))
  expect(hook.el.dataset.dirty).toBeUndefined()
})

test("paste and drop populate the LiveView file input and notify its upload listeners", () => {
  const {hook} = mountHook(Composer, "textarea")
  const picker = document.querySelector("input")
  let changes = 0
  picker.addEventListener("change", () => changes++)
  const transfer = new DataTransfer()
  transfer.items.add(image("paste.png"))
  const paste = new Event("paste", {cancelable:true})
  Object.defineProperty(paste, "clipboardData", {value:transfer})
  hook.el.dispatchEvent(paste)
  expect(paste.defaultPrevented).toBe(true)
  expect(picker.files[0].name).toBe("paste.png")
  const drop = new Event("drop", {cancelable:true})
  Object.defineProperty(drop, "dataTransfer", {value:{types:["Files"], files:transfer.files}})
  hook.box().dispatchEvent(drop)
  expect(drop.defaultPrevented).toBe(true)
  expect(changes).toBe(2)
  expect(hook.attach([])).toBe(false)
  expect(hook.attach([new File(["x"], "bad.pdf")])).toBe(true)
  expect(hook.box().querySelector("[data-composer-note]").hidden).toBe(false)
})

test("drag feedback ignores text and remains while moving within the composer", () => {
  const {hook} = mountHook(Composer, "textarea")
  const drag = new Event("dragover", {cancelable:true})
  Object.defineProperty(drag,"dataTransfer",{value:{types:["Files"]}})
  hook.box().dispatchEvent(drag)
  expect(hook.box().classList.contains("dragging")).toBe(true)
  hook.box().dispatchEvent(new MouseEvent("dragleave",{relatedTarget:hook.el}))
  expect(hook.box().classList.contains("dragging")).toBe(true)
  hook.box().dispatchEvent(new MouseEvent("dragleave"))
  expect(hook.box().classList.contains("dragging")).toBe(false)
  expect(hook.attach(null)).toBe(false)
})

test("an empty reconnect patch restores the draft but an acknowledgement clears it", () => {
  const {hook, receive} = mountHook(Composer,"textarea")
  hook.el.value = "Unsent after reconnect"
  hook.el.dispatchEvent(new Event("input"))
  hook.el.value = ""
  hook.updated()
  expect(hook.el.value).toBe("Unsent after reconnect")
  receive("composer:clear")
  hook.updated()
  expect(hook.el.value).toBe("")
})

test("tearing down a composer whose textarea has already left the document", () => {
  const {hook} = mountHook(Composer, "textarea")
  const box = document.querySelector("[data-composer-box]")

  // Moving between tracks changes the textarea's id, so LiveView replaces the
  // element rather than patching it, and calls `destroyed` on a node that has
  // been taken out of its parent. Walking up from it to find the box again
  // then finds nothing at all --- not the box, not the form, not a parent ---
  // which is why the box is the one remembered at mount.
  hook.el.remove()
  expect(hook.el.closest("[data-composer-box]")).toBe(null)
  expect(hook.el.form).toBe(null)

  expect(() => hook.destroyed()).not.toThrow()
  // And the listeners came off the element they went on to, not off whatever
  // a second lookup would have returned.
  box.dispatchEvent(new Event("dragover"))
  expect(box.classList.contains("dragging")).toBe(false)
})

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


test("retry preserves drafts and attachments, then restores a message for review", () => {
  const {hook, receive} = mountHook(Composer, "textarea")
  hook.el.value = "Unsent work"
  receive("composer:retry", {text: "Earlier message", images: false})
  expect(hook.el.value).toBe("Unsent work")
  expect(document.querySelector("[data-composer-note]").textContent).toContain("Your draft is still here")
  hook.el.value = ""
  const retained = document.createElement("button")
  retained.setAttribute("phx-click", "clear-attachments")
  hook.box().appendChild(retained)
  receive("composer:retry", {text: "Earlier message", images: false})
  expect(hook.el.value).toBe("")
  retained.remove()
  receive("composer:retry", {text: "Earlier message", images: true})
  expect(hook.el.value).toBe("Earlier message")
  expect(localStorage.getItem("ravix.draft.track:a")).toBe("Earlier message")
  expect(document.querySelector("[data-composer-note]").textContent).toContain("reattach its images")
  receive("composer:clear")
  receive("composer:retry", {text: "Text only", images: false})
  expect(document.querySelector("[data-composer-note]").textContent).toBe("Review your message, then send to retry.")
})

test("a sent or discarded draft thread's text is forgotten without touching this box", () => {
  localStorage.setItem("ravix.draft.track:a:thread:draft:d1", "First message")
  localStorage.setItem("ravix.draft.track:a", "This thread's words")
  const {hook, receive} = mountHook(Composer, "textarea")
  receive("composer:forget", {key: "track:a:thread:draft:d1"})
  expect(localStorage.getItem("ravix.draft.track:a:thread:draft:d1")).toBeNull()
  expect(hook.el.value).toBe("This thread's words")
  expect(localStorage.getItem("ravix.draft.track:a")).toBe("This thread's words")
  const unavailable = localStorage.removeItem
  localStorage.removeItem = () => { throw new Error("storage disabled") }
  try {
    expect(() => receive("composer:forget", {key: "track:a"})).not.toThrow()
  } finally {
    localStorage.removeItem = unavailable
  }
})

const commentBox = `<form><div data-composer-box><div data-composer-note hidden></div>
  <textarea data-mode="comment" aria-controls="mention-options"></textarea>
  <ul id="mention-options" role="listbox" data-mention-options>
    <li id="mention-option-alice" role="option" aria-selected="false" data-login="alice">@alice</li>
    <li id="mention-option-alan" role="option" aria-selected="false" data-login="alan">@alan</li>
    <li id="mention-option-bob" role="option" aria-selected="false" data-login="bob">@bob</li>
  </ul><input type="file"></div></form>`

function type(el, text) {
  el.value = text
  el.setSelectionRange(text.length, text.length)
  el.dispatchEvent(new Event("input"))
}

const shown = () => Array.from(document.querySelectorAll("[role=option]")).filter(o => !o.hidden).map(o => o.dataset.login)

test("mentionQuery finds the @partial at the caret and nothing inside words, paths or code", async () => {
  const {mentionQuery} = await import("../js/hooks/composer.js")
  expect(mentionQuery("hi @al", 6)).toEqual({start: 3, query: "al"})
  expect(mentionQuery("@", 1)).toEqual({start: 0, query: ""})
  expect(mentionQuery("mail me@al", 10)).toBeNull()
  expect(mentionQuery("see /@al", 8)).toBeNull()
  expect(mentionQuery("`@al", 4)).toBeNull()
  expect(mentionQuery("@al done", 8)).toBeNull()
})

test("in Comment mode @ opens the people list, filters it, and arrows and Enter choose without sending", () => {
  document.body.innerHTML = commentBox
  const {hook} = mountHook(Composer, "textarea")
  const menu = document.getElementById("mention-options")
  let submits = 0
  hook.el.form.addEventListener("submit", e => {e.preventDefault(); submits++})

  type(hook.el, "thanks @al")
  expect(menu.hasAttribute("data-open")).toBe(true)
  expect(shown()).toEqual(["alice", "alan"])
  expect(hook.el.getAttribute("aria-activedescendant")).toBe("mention-option-alice")

  key(hook.el, "ArrowDown")
  expect(hook.el.getAttribute("aria-activedescendant")).toBe("mention-option-alan")
  key(hook.el, "ArrowDown")
  expect(hook.el.getAttribute("aria-activedescendant")).toBe("mention-option-alice")
  key(hook.el, "ArrowUp")
  hook.updated()
  expect(hook.el.getAttribute("aria-activedescendant")).toBe("mention-option-alan")
  key(hook.el, "Enter")
  expect(submits).toBe(0)
  expect(hook.el.value).toBe("thanks @alan ")
  expect(menu.hasAttribute("data-open")).toBe(false)
  expect(hook.el.hasAttribute("aria-activedescendant")).toBe(false)

  // Nobody matches: the list stays shut and Enter sends as usual.
  type(hook.el, "thanks @zed")
  expect(menu.hasAttribute("data-open")).toBe(false)
  key(hook.el, "Enter")
  expect(submits).toBe(1)
})

test("a click or Tab picks a person, Escape closes the list and keeps the draft", () => {
  document.body.innerHTML = commentBox
  localStorage.clear()
  const {hook} = mountHook(Composer, "textarea")
  const menu = document.getElementById("mention-options")

  type(hook.el, "@b")
  const bob = document.getElementById("mention-option-bob")
  const down = new MouseEvent("mousedown", {bubbles: true, cancelable: true})
  bob.dispatchEvent(down)
  expect(down.defaultPrevented).toBe(true)
  expect(hook.el.value).toBe("@bob ")

  type(hook.el, "@bob and @")
  expect(shown()).toEqual(["alice", "alan", "bob"])
  key(hook.el, "Tab")
  expect(hook.el.value).toBe("@bob and @alice ")

  type(hook.el, "@a")
  key(hook.el, "Escape")
  expect(menu.hasAttribute("data-open")).toBe(false)
  expect(hook.el.value).toBe("@a")
  // Other keys fall through to the box.
  type(hook.el, "@a")
  expect(key(hook.el, "x").defaultPrevented).toBe(false)
})

test("Comment mode is text only, and Ask mode has no mention list", () => {
  document.body.innerHTML = commentBox
  const {hook} = mountHook(Composer, "textarea")
  const picker = document.querySelector("input")
  const transfer = new DataTransfer()
  transfer.items.add(image("shot.png"))
  const paste = new Event("paste", {cancelable: true})
  paste.clipboardData = {files: transfer.files}
  hook.el.dispatchEvent(paste)
  expect(paste.defaultPrevented).toBe(true)
  expect(picker.files?.length ?? 0).toBe(0)
  expect(document.querySelector("[data-composer-note]").textContent).toContain("text only")

  hook.el.dataset.mode = "ask"
  type(hook.el, "@al")
  expect(document.getElementById("mention-options").hasAttribute("data-open")).toBe(false)
  hook.active = document.getElementById("mention-option-alice")
  hook.updated()
  expect(hook.active).toBeNull()
})

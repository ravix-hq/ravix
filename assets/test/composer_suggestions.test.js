import {beforeEach, expect, test} from "bun:test"
import {Composer, commandQuery, fileQuery, fuzzy, rankCommands, rankFiles, shortcutLabel} from "../js/hooks/composer.js"
import {key, mountHook} from "./setup.js"

const COMMANDS = [
  {name: "review", description: "Review the branch", hint: "what to focus on", source: "agent"},
  {name: "compact", description: "Summarise the conversation", source: "agent"},
  {name: "stop", description: "Stop the agent's current turn", event: "interrupt", source: "ravix"},
  {name: "changes", description: "Open the Changes tab", event: "panel", value: {name: "changes"}, source: "ravix"},
]

const PATHS = ["README.md", "mix.exs", "lib/ravix/router.ex", "lib/ravix_web/router.ex", "assets/js/app.js"]

beforeEach(() => {
  document.body.innerHTML = `<form><div data-composer-box>
    <div data-composer-note hidden></div>
    <textarea id="composer-t1" data-draft-key="track:a" data-mode="ask" aria-controls="composer-suggestions"
      data-files-event="mention-files"></textarea>
    <ul id="composer-suggestions" role="listbox" data-composer-suggestions></ul>
    <p class="sr-only" role="status" data-composer-announce></p>
    <span data-composer-shortcut><kbd>Ctrl+L</kbd> to focus</span>
    <button>Send</button></div></form>
    <div phx-hook="Terminal"><textarea id="term"></textarea></div>`
  document.querySelector("textarea").dataset.commands = JSON.stringify(COMMANDS)
})

function type(el, text) {
  el.value = text
  el.setSelectionRange(text.length, text.length)
  el.dispatchEvent(new Event("input"))
}

const menu = () => document.getElementById("composer-suggestions")
const shown = () => Array.from(menu().querySelectorAll("[role=option]:not([aria-disabled=true])"))
const announced = () => document.querySelector("[data-composer-announce]").textContent
const selected = () => menu().querySelector("[aria-selected=true]")

function counting(hook) {
  let submits = 0
  hook.el.form.addEventListener("submit", e => {
    e.preventDefault()
    submits++
  })
  return () => submits
}

test("queries are read at the caret: @ after a space or the start, / only as the whole message so far", () => {
  expect(fileQuery("see @lib/ro", 11)).toEqual({start: 4, query: "lib/ro"})
  expect(fileQuery("@", 1)).toEqual({start: 0, query: ""})
  expect(fileQuery("mail me@example", 15)).toBeNull()
  expect(fileQuery("done @x now", 11)).toBeNull()
  expect(commandQuery("/rev", 4)).toEqual({start: 0, query: "rev"})
  expect(commandQuery("/", 1)).toEqual({start: 0, query: ""})
  expect(commandQuery("please /rev", 11)).toBeNull()
  expect(commandQuery("/review the diff", 16)).toBeNull()
})

test("fuzzy ranking prefers file names and runs, and keeps shallow files first when nothing is typed", () => {
  expect(fuzzy("rtr", "router")).toMatchObject({marks: [0, 3, 5]})
  expect(fuzzy("zz", "router")).toBeNull()
  expect(fuzzy("ro", "router").score).toBeGreaterThan(fuzzy("ro", "error").score)
  expect(rankFiles("", PATHS, 2).map(r => r.path)).toEqual(["README.md", "mix.exs"])
  expect(rankFiles("router", PATHS).map(r => r.path)).toEqual(["lib/ravix/router.ex", "lib/ravix_web/router.ex"])
  expect(rankFiles("app", PATHS)[0].path).toBe("assets/js/app.js")
  expect(rankFiles("qqq", PATHS)).toEqual([])
  expect(rankCommands("c", COMMANDS).map(r => r.command.name)).toEqual(["compact", "changes"])
  expect(rankCommands("ew", COMMANDS).map(r => r.command.name)).toEqual(["review"])
  expect(rankCommands("", COMMANDS)).toHaveLength(4)
  expect(shortcutLabel("MacIntel")).toBe("⌘L")
  expect(shortcutLabel("Win32")).toBe("Ctrl+L")
})

test("@ asks for the track's files once, says it is searching, then filters as the person types", () => {
  const {hook, events, receive} = mountHook(Composer, "textarea")
  type(hook.el, "Look at @")
  type(hook.el, "Look at @r")
  expect(events.filter(e => e.name === "mention-files")).toHaveLength(1)
  expect(menu().hasAttribute("data-open")).toBe(true)
  expect(menu().getAttribute("aria-label")).toBe("Files to mention")
  expect(menu().querySelector("[aria-disabled=true]").textContent).toBe("Searching files…")
  expect(announced()).toBe("Searching files…")
  expect(hook.el.hasAttribute("aria-activedescendant")).toBe(false)

  receive("composer:files", {paths: PATHS, truncated: false})
  expect(shown().map(o => o.textContent)).toContain("router.exlib/ravix/")
  type(hook.el, "Look at @router")
  expect(shown().map(o => o.textContent)).toEqual(["router.exlib/ravix/", "router.exlib/ravix_web/"])
  expect(shown()[0].querySelectorAll("mark")).toHaveLength(6)
  expect(announced()).toBe("2 files. Up and down to choose, Enter to mention.")
  expect(hook.el.getAttribute("aria-activedescendant")).toBe(shown()[0].id)
  expect(shown()[0].getAttribute("aria-selected")).toBe("true")
})

test("arrow keys move and wrap, Enter mentions the highlighted file without sending, and the list closes", () => {
  const {hook, receive} = mountHook(Composer, "textarea")
  const submits = counting(hook)
  receive("composer:files", {paths: PATHS, truncated: false})
  type(hook.el, "Fix @router")

  expect(key(hook.el, "ArrowDown").defaultPrevented).toBe(true)
  expect(selected().textContent).toBe("router.exlib/ravix_web/")
  expect(hook.el.getAttribute("aria-activedescendant")).toBe(selected().id)
  key(hook.el, "ArrowDown")
  expect(selected().textContent).toBe("router.exlib/ravix/")
  key(hook.el, "ArrowUp")
  expect(selected().textContent).toBe("router.exlib/ravix_web/")

  expect(key(hook.el, "Enter").defaultPrevented).toBe(true)
  expect(submits()).toBe(0)
  expect(hook.el.value).toBe("Fix @lib/ravix_web/router.ex ")
  expect(hook.el.selectionStart).toBe(hook.el.value.length)
  expect(localStorage.getItem("ravix.draft.track:a")).toBe("Fix @lib/ravix_web/router.ex ")
  expect(menu().hasAttribute("data-open")).toBe(false)
  expect(menu().children).toHaveLength(0)
  expect(hook.el.hasAttribute("aria-activedescendant")).toBe(false)
  expect(announced()).toBe("lib/ravix_web/router.ex mentioned.")

  // With the list closed, Enter is Enter again.
  key(hook.el, "Enter")
  expect(submits()).toBe(1)
})

test("Escape closes the list and keeps the draft; the same @ stays closed and the next one opens", () => {
  localStorage.setItem("ravix.draft.track:a", "draft")
  const {hook, receive} = mountHook(Composer, "textarea")
  receive("composer:files", {paths: PATHS, truncated: false})
  type(hook.el, "see @mi")
  expect(key(hook.el, "Escape").defaultPrevented).toBe(true)
  expect(menu().hasAttribute("data-open")).toBe(false)
  expect(localStorage.getItem("ravix.draft.track:a")).toBe("see @mi")
  type(hook.el, "see @mix")
  expect(menu().hasAttribute("data-open")).toBe(false)
  type(hook.el, "see @mix and @")
  expect(menu().hasAttribute("data-open")).toBe(true)
  // Escape with nothing open is the old Escape.
  key(hook.el, "Escape")
  key(hook.el, "Escape")
  expect(localStorage.getItem("ravix.draft.track:a")).toBeNull()
})

test("Tab and a click also choose, and a file list that failed or was cut short says so", () => {
  const {hook, events, receive} = mountHook(Composer, "textarea")
  type(hook.el, "@")
  receive("composer:files", {paths: [], error: "This track's machine is asleep."})
  expect(menu().querySelector("[aria-disabled=true]").textContent).toBe("This track's machine is asleep.")
  expect(announced()).toBe("This track's machine is asleep.")
  expect(key(hook.el, "ArrowDown").defaultPrevented).toBe(false)

  // A failed read is asked again by the next `@`.
  type(hook.el, "@ @")
  expect(events.filter(e => e.name === "mention-files")).toHaveLength(2)
  receive("composer:files", {paths: PATHS, truncated: true})
  expect(menu().querySelector("[aria-disabled=true]").textContent).toContain("Not every file was searched")
  type(hook.el, "@ @zzz")
  expect(menu().querySelector("[aria-disabled=true]").textContent).toBe("No files match.")

  type(hook.el, "@ @mix")
  key(hook.el, "Tab")
  expect(hook.el.value).toBe("@ @mix.exs ")

  type(hook.el, "then @READ")
  const down = new MouseEvent("mousedown", {bubbles: true, cancelable: true})
  shown()[0].querySelector("strong").dispatchEvent(down)
  expect(down.defaultPrevented).toBe(true)
  expect(hook.el.value).toBe("then @README.md ")

  // The status line is not something to choose.
  type(hook.el, "@zzz")
  menu().querySelector("[aria-disabled=true]").dispatchEvent(new MouseEvent("mousedown", {bubbles: true}))
  expect(hook.el.value).toBe("@zzz")
})

test("/ lists the agent's commands and Ravix's, filters by name, and Enter puts an agent command in the box", () => {
  const {hook} = mountHook(Composer, "textarea")
  const submits = counting(hook)
  type(hook.el, "/")
  expect(menu().getAttribute("aria-label")).toBe("Commands")
  expect(shown().map(o => o.querySelector("strong").textContent)).toEqual(["/review", "/compact", "/stop", "/changes"])
  expect(shown()[0].textContent).toContain("Review the branch (what to focus on)")
  expect(shown()[2].querySelector(".suggestion-source").textContent).toBe("Ravix")
  expect(announced()).toBe("4 commands. Up and down to choose, Enter to pick.")

  type(hook.el, "/c")
  expect(shown().map(o => o.querySelector("strong").textContent)).toEqual(["/compact", "/changes"])
  key(hook.el, "ArrowUp")
  expect(selected().querySelector("strong").textContent).toBe("/changes")
  key(hook.el, "ArrowUp")
  type(hook.el, "/re")
  key(hook.el, "Enter")
  expect(hook.el.value).toBe("/review ")
  expect(submits()).toBe(0)
  expect(menu().hasAttribute("data-open")).toBe(false)
})

test("a Ravix action runs its event instead of being sent, and unknown /text is sent as text", () => {
  const {hook, events} = mountHook(Composer, "textarea")
  const submits = counting(hook)
  type(hook.el, "/chan")
  key(hook.el, "Enter")
  expect(events).toContainEqual({name: "panel", payload: {name: "changes"}})
  expect(hook.el.value).toBe("")
  expect(submits()).toBe(0)

  type(hook.el, "/st")
  key(hook.el, "Tab")
  expect(events).toContainEqual({name: "interrupt", payload: {}})

  type(hook.el, "/deploy")
  expect(menu().hasAttribute("data-open")).toBe(false)
  key(hook.el, "Enter")
  expect(submits()).toBe(1)
  expect(hook.el.value).toBe("/deploy")

  // Once the command has an argument it is text, whatever it starts with.
  type(hook.el, "/review the router")
  expect(menu().hasAttribute("data-open")).toBe(false)
})

test("a patch keeps the open list and its highlight, and new commands appear; blur closes it", () => {
  const {hook} = mountHook(Composer, "textarea")
  type(hook.el, "/")
  key(hook.el, "ArrowDown")
  // LiveView rewrites the textarea's attributes from the template.
  hook.el.removeAttribute("aria-activedescendant")
  hook.el.dataset.commands = JSON.stringify([{name: "plan", source: "agent"}, ...COMMANDS])
  hook.updated()
  expect(shown()).toHaveLength(5)
  expect(selected().querySelector("strong").textContent).toBe("/compact")
  expect(hook.el.getAttribute("aria-activedescendant")).toBe(selected().id)
  hook.el.dataset.commands = "not json"
  hook.updated()
  expect(menu().hasAttribute("data-open")).toBe(false)
  type(hook.el, "@")
  hook.el.dispatchEvent(new Event("blur"))
  expect(menu().hasAttribute("data-open")).toBe(false)
})

test("Comment mode keeps its people list and opens neither Ask menu", () => {
  const el = document.querySelector("textarea")
  el.dataset.mode = "comment"
  const {hook, events} = mountHook(Composer, "#composer-t1")
  type(hook.el, "/")
  type(hook.el, "@")
  expect(menu().hasAttribute("data-open")).toBe(false)
  expect(events).toEqual([])
})

test("⌘L or Ctrl+L focuses the box from the page, but not from the terminal", () => {
  const {hook} = mountHook(Composer, "#composer-t1")
  expect(document.querySelector("[data-composer-shortcut]").textContent).toBe(`${shortcutLabel()} to focus`)
  hook.el.value = "half a thought"
  document.body.focus()

  const ctrl = key(document.body, "l", {ctrlKey: true})
  expect(ctrl.defaultPrevented).toBe(true)
  expect(document.activeElement).toBe(hook.el)
  expect(hook.el.selectionStart).toBe(14)

  hook.el.blur()
  key(document.body, "L", {metaKey: true})
  expect(document.activeElement).toBe(hook.el)

  const terminal = document.getElementById("term")
  terminal.focus()
  expect(key(terminal, "l", {ctrlKey: true}).defaultPrevented).toBe(false)
  expect(document.activeElement).toBe(terminal)
  expect(key(document.body, "l", {ctrlKey: true, shiftKey: true}).defaultPrevented).toBe(false)
  expect(key(document.body, "k", {ctrlKey: true}).defaultPrevented).toBe(false)

  hook.el.disabled = true
  expect(key(document.body, "l", {ctrlKey: true}).defaultPrevented).toBe(false)
  hook.destroyed()
  hook.el.disabled = false
  expect(key(document.body, "l", {ctrlKey: true}).defaultPrevented).toBe(false)
})

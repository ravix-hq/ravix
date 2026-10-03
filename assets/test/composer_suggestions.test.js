import {beforeEach, expect, test} from "bun:test"
import {Composer, commandQuery, fileQuery, fuzzy, purpose, rankCommands, rankFiles, shortcutLabel} from "../js/hooks/composer.js"
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
    <ul id="composer-suggestions" role="listbox" aria-label="Suggestions" hidden data-composer-suggestions></ul>
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
  // The `r` in `src` is not where "rout" starts.
  expect(rankFiles("rout", ["test/router.test.ts", "src/router.ts"])[0].path).toBe("src/router.ts")
  expect(fuzzy("rout", "src/router.ts").marks).toEqual([4, 5, 6, 7])
  expect(fuzzy("ab", "xab/ab").marks).toEqual([4, 5])
  expect(fuzzy("ab", "ab/xab").marks).toEqual([0, 1])
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
  expect(menu().hidden).toBe(false)
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
  expect(menu().hidden).toBe(true)
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
  expect(menu().hidden).toBe(true)
  expect(localStorage.getItem("ravix.draft.track:a")).toBe("see @mi")
  type(hook.el, "see @mix")
  expect(menu().hidden).toBe(true)
  type(hook.el, "see @mix and @")
  expect(menu().hidden).toBe(false)
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
  expect(menu().querySelector("[aria-disabled=true]").textContent).toBe("No files match")

  type(hook.el, "@ @mix")
  key(hook.el, "Tab")
  expect(hook.el.value).toBe("@ @mix.exs ")

  type(hook.el, "then @READ")
  const down = new MouseEvent("mousedown", {bubbles: true, cancelable: true})
  shown()[0].querySelector("strong").dispatchEvent(down)
  expect(down.defaultPrevented).toBe(true)
  expect(hook.el.value).toBe("then @README.md ")

  // The list's own edge keeps the caret in the box.
  type(hook.el, "then @READ")
  const edge = new MouseEvent("mousedown", {bubbles: true, cancelable: true})
  menu().dispatchEvent(edge)
  expect(edge.defaultPrevented).toBe(true)
  expect(hook.el.value).toBe("then @READ")

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
  expect(menu().hidden).toBe(true)
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
  expect(menu().hidden).toBe(true)
  key(hook.el, "Enter")
  expect(submits()).toBe(1)
  expect(hook.el.value).toBe("/deploy")

  // Once the command has an argument it is text, whatever it starts with.
  type(hook.el, "/review the router")
  expect(menu().hidden).toBe(true)
})

test("a patch keeps the open list and its highlight, and new commands appear; blur closes it", async () => {
  const {hook} = mountHook(Composer, "textarea")
  type(hook.el, "/")
  key(hook.el, "ArrowDown")
  // LiveView rewrites the textarea's attributes from the template, and
  // strips from the ignored list any `data-` attribute the template lacks.
  hook.el.removeAttribute("aria-activedescendant")
  for (const {name} of [...menu().attributes]) {
    if (name.startsWith("data-") && name !== "data-composer-suggestions") menu().removeAttribute(name)
  }
  expect(menu().hidden).toBe(false)
  hook.el.dataset.commands = JSON.stringify([{name: "plan", source: "agent"}, ...COMMANDS])
  hook.updated()
  expect(shown()).toHaveLength(5)
  expect(selected().querySelector("strong").textContent).toBe("/compact")
  expect(hook.el.getAttribute("aria-activedescendant")).toBe(selected().id)
  hook.el.dataset.commands = "not json"
  hook.updated()
  expect(menu().hidden).toBe(true)
  hook.el.focus()
  type(hook.el, "@")
  // LiveView blurs the box while it patches and focuses it again at once.
  hook.el.dispatchEvent(new Event("blur"))
  await new Promise(resolve => setTimeout(resolve))
  expect(menu().hidden).toBe(false)
  hook.el.blur()
  await new Promise(resolve => setTimeout(resolve))
  expect(menu().hidden).toBe(true)
})

test("Comment mode keeps its people list and opens neither Ask menu", () => {
  const el = document.querySelector("textarea")
  el.dataset.mode = "comment"
  const {hook, events} = mountHook(Composer, "#composer-t1")
  type(hook.el, "/")
  type(hook.el, "@")
  expect(menu().hidden).toBe(true)
  expect(events).toEqual([])
})

test("⌘L or Ctrl+L focuses the box from the page, but not from the terminal", async () => {
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
  // The blurs above each queued the box's blur timer. Let them run here:
  // aborting happy-dom with one still queued leaves its timers stalled, and
  // every `setTimeout` in whichever test file runs next never fires.
  await new Promise(resolve => setTimeout(resolve))
})

// RAV-95 ─────────────────────────────────────────────────────────────────

// Everything the page says, less what is typed in the box.
function textOutsideTheBox() {
  const copy = document.body.cloneNode(true)
  for (const el of copy.querySelectorAll("textarea, [data-composer-announce]")) el.remove()
  return copy.textContent
}

test("the @ that opens the list stays in the box: nothing outside it draws one, searching, found or on to /", () => {
  const {hook, receive} = mountHook(Composer, "textarea")
  expect(textOutsideTheBox()).not.toContain("@")
  type(hook.el, "@")
  expect(menu().hidden).toBe(false)
  expect(textOutsideTheBox()).not.toContain("@")
  receive("composer:files", {paths: PATHS, truncated: false})
  type(hook.el, "@rout")
  expect(shown().length).toBeGreaterThan(0)
  expect(textOutsideTheBox()).not.toContain("@")
  type(hook.el, "/")
  expect(menu().getAttribute("aria-label")).toBe("Commands")
  expect(textOutsideTheBox()).not.toContain("@")
})

test("searching shows a spinner and marks the list busy, then No files match once the files arrive", () => {
  const {hook, receive} = mountHook(Composer, "textarea")
  type(hook.el, "see @zzz")
  const status = menu().querySelector("[aria-disabled=true]")
  expect(status.textContent).toBe("Searching files…")
  expect(status.querySelector(".suggestion-spinner[aria-hidden=true]")).not.toBeNull()
  expect(menu().getAttribute("aria-busy")).toBe("true")

  receive("composer:files", {paths: PATHS, truncated: false})
  const done = menu().querySelector("[aria-disabled=true]")
  expect(done.textContent).toBe("No files match")
  expect(done.querySelector(".suggestion-spinner")).toBeNull()
  expect(menu().hasAttribute("aria-busy")).toBe(false)
  expect(announced()).toBe("No files match")

  type(hook.el, "see ")
  expect(menu().hidden).toBe(true)
  expect(menu().hasAttribute("aria-busy")).toBe(false)
})

test("/ highlights its first row as it opens, and the arrow keys move the highlight and aria-activedescendant", () => {
  const {hook} = mountHook(Composer, "textarea")
  type(hook.el, "/")
  const rows = shown()
  expect(rows[0].getAttribute("aria-selected")).toBe("true")
  expect(rows.slice(1).every(r => r.getAttribute("aria-selected") === "false")).toBe(true)
  expect(hook.el.getAttribute("aria-activedescendant")).toBe(rows[0].id)

  key(hook.el, "ArrowDown")
  expect(selected().querySelector("strong").textContent).toBe("/compact")
  expect(hook.el.getAttribute("aria-activedescendant")).toBe(selected().id)
  expect(menu().querySelectorAll("[aria-selected=true]")).toHaveLength(1)
  key(hook.el, "ArrowUp")
  key(hook.el, "ArrowUp")
  expect(selected().querySelector("strong").textContent).toBe("/changes")
  expect(hook.el.getAttribute("aria-activedescendant")).toBe(selected().id)
})

test("moving the highlight scrolls the list, never the page around it", () => {
  const {hook} = mountHook(Composer, "textarea")
  const into = HTMLElement.prototype.scrollIntoView
  let pageScrolls = 0
  HTMLElement.prototype.scrollIntoView = () => pageScrolls++
  try {
    type(hook.el, "/")
    // happy-dom lays nothing out: rows 30px apart in a 60px window.
    Object.defineProperty(menu(), "clientHeight", {configurable: true, value: 60})
    shown().forEach((row, i) => {
      Object.defineProperty(row, "offsetTop", {configurable: true, value: i * 30})
      Object.defineProperty(row, "offsetHeight", {configurable: true, value: 30})
    })
    key(hook.el, "ArrowDown")
    expect(menu().scrollTop).toBe(0)
    // The rows are drawn again on each move; the next ones get the same layout.
    const layout = () => shown().forEach((row, i) => {
      Object.defineProperty(row, "offsetTop", {configurable: true, value: i * 30})
      Object.defineProperty(row, "offsetHeight", {configurable: true, value: 30})
    })
    layout()
    menu().scrollTop = 0
    key(hook.el, "ArrowDown")
    layout()
    key(hook.el, "ArrowDown")
    layout()
    key(hook.el, "ArrowUp")
    key(hook.el, "ArrowDown")
    expect(pageScrolls).toBe(0)
  } finally {
    HTMLElement.prototype.scrollIntoView = into
  }
})

test.skip("deprecated literal/cosmetic: a command's own purpose: the first sentence, without the skill boilerplate, or else its name", () => {
  expect(purpose("Use this skill when users are modifying system configuration, starting dev servers. Also use it for checkpoints.", "sprite"))
    .toBe("Users are modifying system configuration, starting dev servers")
  expect(purpose("Use when adding regression tests or raising coverage. Covers hooks.", "ravix-testing"))
    .toBe("Adding regression tests or raising coverage")
  expect(purpose("use this when, the build is red!", "fix")).toBe("The build is red")
  expect(purpose("Use this skill when users want external APIs (GitHub, Slack, etc.) with keys. More.", "api"))
    .toBe("Users want external APIs (GitHub, Slack, etc.) with keys")
  expect(purpose("Summarise, e.g. a long thread. Then stop.", "compact")).toBe("Summarise, e.g. a long thread")
  // Only those phrases; "whenever" is not "when".
  expect(purpose("Use this skill whenever you draw a chart.", "dataviz")).toBe("Use this skill whenever you draw a chart")
  expect(purpose("Review the changes on this branch", "review")).toBe("Review the changes on this branch")
  expect(purpose("Use this skill when.", "empty")).toBe("empty")
  expect(purpose("Use when:  …", "dots")).toBe("dots")
  expect(purpose("", "bare")).toBe("bare")
  expect(purpose(undefined, "bare")).toBe("bare")
  expect(purpose("  Use   this skill  when   the\n  sky falls  ", "sky")).toBe("The sky falls")
})

test.skip("deprecated literal/cosmetic: / rows show each command's purpose, keep the whole description in the title, and fall back to the name", () => {
  document.querySelector("textarea").dataset.commands = JSON.stringify([
    {name: "sprite", description: "Use this skill when users start dev servers. Also for checkpoints.", source: "agent"},
    {name: "blank", description: "Use this skill when.", source: "agent"},
    {name: "plain", source: "agent"},
  ])
  const {hook} = mountHook(Composer, "textarea")
  type(hook.el, "/")
  const [sprite, blank, plain] = shown()
  expect(sprite.querySelector(".dim").textContent).toBe("Users start dev servers")
  expect(sprite.title).toBe("Use this skill when users start dev servers. Also for checkpoints.")
  expect(blank.querySelector(".dim").textContent).toBe("blank")
  expect(plain.querySelector(".dim").textContent).toBe("")
  expect(plain.hasAttribute("title")).toBe(false)
})

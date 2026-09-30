import {afterAll, beforeAll, expect, test} from "bun:test"
import {ChipMenu} from "../js/hooks/chip_menu.js"
import {ProjectFormFocus} from "../js/hooks/project_form_focus.js"
import {SubmitOnEnter} from "../js/hooks/submit_on_enter.js"
import {key, mountHook} from "./setup.js"

// happy-dom has no popover API. This stands in for the browser's part —
// showing, hiding, the `toggle` event and a `popovertarget` click — so the
// tests exercise what the hook adds to it.
const open = new WeakSet()
function toggle(el, state) {
  if (open.has(el) === (state === "open")) return
  state === "open" ? open.add(el) : open.delete(el)
  const event = new Event("toggle")
  event.newState = state
  el.dispatchEvent(event)
}
const invoke = event => {
  const invoker = event.target.closest?.("[popovertarget]")
  const target = invoker && document.getElementById(invoker.getAttribute("popovertarget"))
  if (!target || invoker.disabled) return
  const action = invoker.getAttribute("popovertargetaction") || "toggle"
  toggle(target, action === "hide" || (action === "toggle" && open.has(target)) ? "closed" : "open")
}
beforeAll(() => {
  HTMLElement.prototype.showPopover = function () { toggle(this, "open") }
  HTMLElement.prototype.hidePopover = function () { toggle(this, "closed") }
  document.addEventListener("click", invoke)
})
afterAll(() => {
  delete HTMLElement.prototype.showPopover
  delete HTMLElement.prototype.hidePopover
  document.removeEventListener("click", invoke)
})

// The New track dialog as the server renders it: chips above the prompt,
// the model chip in the footer, the radios in the form by `form=`.
function render() {
  document.body.innerHTML = `<div id="dialog" role="dialog">
    <div class="new-track-chips">
      <div id="repo" class="chip-menu">
        <button type="button" id="repo-trigger" popovertarget="repo-menu" aria-haspopup="dialog" aria-expanded="false">me/beta</button>
        <div id="repo-menu" popover role="dialog">
          <input id="repo-query" type="search" data-jump-query>
          <button type="button" id="repo-alpha" data-chip-close>me/alpha</button>
          <button type="button" id="repo-add">Add a repository…</button>
        </div>
      </div>
    </div>
    <form id="new-track-form" data-focus="#prompt">
      <textarea id="prompt" name="new_track[prompt]"></textarea>
    </form>
    <div class="dialog-foot">
      <div id="model" class="chip-menu">
        <button type="button" id="model-trigger" popovertarget="model-menu" aria-haspopup="dialog" aria-expanded="false">Claude Code · Opus</button>
        <div id="model-menu" popover role="dialog">
          <label><input type="radio" id="claude" name="new_track[runtime]" value="claude" form="new-track-form" checked>Claude Code</label>
          <label><input type="radio" id="codex" name="new_track[runtime]" value="codex" form="new-track-form">Codex</label>
          <label id="opus-label"><input type="radio" id="opus" name="new_track[model]" value="opus" form="new-track-form" checked data-chip-close><span id="opus-name">Opus</span></label>
          <label><input type="radio" id="sonnet" name="new_track[model]" value="sonnet" form="new-track-form" data-chip-close>Sonnet</label>
        </div>
      </div>
      <button type="submit" id="create" form="new-track-form">Create</button>
    </div>
  </div>`
  const form = document.querySelector("#new-track-form")
  const submits = []
  form.addEventListener("submit", e => { e.preventDefault(); submits.push(e.submitter?.id) })
  // The dialog closes on a window Escape, as `phx-window-keydown` does.
  const dismissed = []
  const dismiss = e => { if (e.key === "Escape") dismissed.push(e.target.id) }
  window.addEventListener("keydown", dismiss)
  const repo = mountHook(ChipMenu, "#repo").hook
  const model = mountHook(ChipMenu, "#model").hook
  const $ = id => document.getElementById(id)
  return {$, repo, model, submits, dismissed, cleanup: () => window.removeEventListener("keydown", dismiss)}
}

test("the dialog opens with the prompt focused, not the chip before it", () => {
  const {$, cleanup} = render()
  $("repo-trigger").focus()
  document.activeElement.blur()
  mountHook(ProjectFormFocus, "#new-track-form")
  expect(document.activeElement).toBe($("prompt"))
  cleanup()
})

test("a chip opens its popover, marks itself expanded and moves focus in", () => {
  const {$, cleanup} = render()
  $("repo-trigger").click()
  expect($("repo-trigger").getAttribute("aria-expanded")).toBe("true")
  expect(document.activeElement).toBe($("repo-query"))

  // A radio menu focuses the current choice.
  $("model-trigger").click()
  expect($("model-trigger").getAttribute("aria-expanded")).toBe("true")
  expect(document.activeElement).toBe($("claude"))
  cleanup()
})

test("ArrowDown or ArrowUp on a chip opens it; other keys and a disabled chip do not", () => {
  const {$, cleanup} = render()
  expect(key($("model-trigger"), "a").defaultPrevented).toBe(false)
  expect($("model-trigger").getAttribute("aria-expanded")).toBe("false")
  expect(key($("model-trigger"), "ArrowUp").defaultPrevented).toBe(true)
  expect(open.has($("model-menu"))).toBe(true)
  // Already open: the key is left to the page.
  expect(key($("model-trigger"), "ArrowDown").defaultPrevented).toBe(false)
  $("model-menu").hidePopover()
  $("repo-trigger").disabled = true
  expect(key($("repo-trigger"), "ArrowDown").defaultPrevented).toBe(false)
  expect(open.has($("repo-menu"))).toBe(false)
  cleanup()
})

test("Escape closes only the popover, returns focus to the chip, then closes the dialog", () => {
  const {$, dismissed, cleanup} = render()
  $("repo-trigger").click()
  const escape = key($("repo-query"), "Escape")
  expect(escape.defaultPrevented).toBe(true)
  expect(dismissed).toEqual([])
  expect(open.has($("repo-menu"))).toBe(false)
  expect($("repo-trigger").getAttribute("aria-expanded")).toBe("false")
  expect(document.activeElement).toBe($("repo-trigger"))

  // With nothing open, Escape is the dialog's again.
  key($("repo-trigger"), "Escape")
  expect(dismissed).toEqual(["repo-trigger"])
  cleanup()
})

test("light dismiss elsewhere leaves focus where the person put it", () => {
  const {$, cleanup} = render()
  $("repo-trigger").click()
  $("prompt").focus()
  $("repo-menu").hidePopover()
  expect(document.activeElement).toBe($("prompt"))
  expect($("repo-trigger").getAttribute("aria-expanded")).toBe("false")
  cleanup()
})

test("picking a repository closes the popover; Add a repository keeps it open", () => {
  const {$, cleanup} = render()
  $("repo-trigger").click()
  $("repo-add").click()
  expect(open.has($("repo-menu"))).toBe(true)
  $("repo-alpha").click()
  expect(open.has($("repo-menu"))).toBe(false)
  expect(document.activeElement).toBe($("repo-trigger"))
  cleanup()
})

test("arrow keys move a radio choice without closing; Enter confirms without submitting", () => {
  const {$, submits, cleanup} = render()
  $("model-trigger").click()

  // An agent: Enter chooses it, the menu stays for its models.
  expect(key($("codex"), "Enter").defaultPrevented).toBe(true)
  expect(open.has($("model-menu"))).toBe(true)

  // A radio clicked by the keyboard (Space, arrows) carries no detail.
  $("sonnet").dispatchEvent(new MouseEvent("click", {bubbles: true, detail: 0}))
  expect(open.has($("model-menu"))).toBe(true)

  expect(key($("sonnet"), "Enter").defaultPrevented).toBe(true)
  expect(open.has($("model-menu"))).toBe(false)
  expect(document.activeElement).toBe($("model-trigger"))
  expect(submits).toEqual([])

  // Other keys inside pass through.
  $("model-trigger").click()
  expect(key($("sonnet"), "a").defaultPrevented).toBe(false)
  cleanup()
})

test("a pointer click on a model closes the menu; on an agent, or a disabled model, it stays", () => {
  const {$, cleanup} = render()
  $("model-trigger").click()
  $("codex").parentElement.dispatchEvent(new MouseEvent("click", {bubbles: true, detail: 1}))
  expect(open.has($("model-menu"))).toBe(true)
  $("opus").disabled = true
  $("opus-name").dispatchEvent(new MouseEvent("click", {bubbles: true, detail: 1}))
  expect(open.has($("model-menu"))).toBe(true)
  $("opus").disabled = false
  $("sonnet").dispatchEvent(new MouseEvent("click", {bubbles: true, detail: 1}))
  expect(open.has($("model-menu"))).toBe(false)
  $("model-trigger").click()
  $("opus-name").dispatchEvent(new MouseEvent("click", {bubbles: true, detail: 1}))
  expect(open.has($("model-menu"))).toBe(false)
  cleanup()
})

test("Enter in the prompt creates through the footer's Create, outside the form", () => {
  const {$, submits, cleanup} = render()
  mountHook(SubmitOnEnter, "#prompt")
  expect(key($("prompt"), "Enter").defaultPrevented).toBe(true)
  expect(submits).toEqual(["create"])
  expect(key($("prompt"), "Enter", {shiftKey: true}).defaultPrevented).toBe(false)
  $("create").disabled = true
  key($("prompt"), "Enter")
  expect(submits).toEqual(["create"])
  cleanup()
})

test("a destroyed chip no longer holds Escape back from the dialog", () => {
  const {$, repo, dismissed, cleanup} = render()
  $("repo-trigger").click()
  repo.destroyed()
  key($("repo-query"), "Escape")
  expect(dismissed).toEqual(["repo-query"])
  cleanup()
})

// RAV-95: more than six models get a search field over the rows.
test("a model search opens focused, hides the rows it does not match, says when none does, and Enter picks the first left", () => {
  document.body.innerHTML = `<form id="f"></form><div id="pick" class="chip-menu">
    <button type="button" id="pick-trigger" popovertarget="pick-menu" aria-haspopup="dialog" aria-expanded="false">Opus</button>
    <div id="pick-menu" popover role="dialog">
      <fieldset><label><input type="radio" id="agent" name="a" form="f" checked>Claude Code</label></fieldset>
      <fieldset>
        <input id="pick-search" type="search" data-chip-filter data-chip-focus>
        ${["Opus 5.5", "Opus 5", "Sonnet 5", "Haiku 4.5", "GPT-6", "GPT-6 Astra", "Gemini"].map((name, i) =>
          `<label id="row-${i}" data-filter-text="${name}"><input type="radio" id="m-${i}" name="m" value="${i}" form="f" ${i === 0 ? "checked" : ""} data-chip-close>${name}</label>`).join("")}
        <p id="empty" data-chip-filter-empty hidden>No models match</p>
      </fieldset>
    </div>
  </div>`
  const {hook} = mountHook(ChipMenu, "#pick")
  const $ = id => document.getElementById(id)
  const visible = () => Array.from(document.querySelectorAll("[data-filter-text]")).filter(r => !r.hidden).map(r => r.id)
  const search = text => {
    $("pick-search").value = text
    $("pick-search").dispatchEvent(new Event("input", {bubbles: true}))
  }

  $("pick-trigger").click()
  expect(document.activeElement).toBe($("pick-search"))
  expect(visible()).toHaveLength(7)

  search("  gpt ")
  expect(visible()).toEqual(["row-4", "row-5"])
  expect($("empty").hidden).toBe(true)

  // A patch redraws the rows as the template has them; the search holds.
  for (const row of document.querySelectorAll("[data-filter-text]")) row.hidden = false
  hook.updated()
  expect(visible()).toEqual(["row-4", "row-5"])

  search("mistral")
  expect(visible()).toEqual([])
  expect($("empty").hidden).toBe(false)
  // Enter with nothing left picks nothing and submits nothing.
  expect(key($("pick-search"), "Enter").defaultPrevented).toBe(true)
  expect($("m-0").checked).toBe(true)

  search("sonnet")
  expect(key($("pick-search"), "Enter").defaultPrevented).toBe(true)
  expect($("m-2").checked).toBe(true)
  expect(open.has($("pick-menu"))).toBe(false)
  expect(document.activeElement).toBe($("pick-trigger"))

  search("")
  expect(visible()).toHaveLength(7)
  // Other input in the popover is not a search.
  $("m-3").dispatchEvent(new Event("input", {bubbles: true}))
  expect(visible()).toHaveLength(7)
})

test("a chip menu without a search is left alone by a patch", () => {
  const {model, $, cleanup} = render()
  model.updated()
  expect($("model-menu").querySelectorAll("[hidden]")).toHaveLength(0)
  cleanup()
})

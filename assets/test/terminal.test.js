import {beforeEach, expect, test} from "bun:test"
import {Terminal} from "../js/hooks/terminal.js"
import {dimensions, key, mountHook} from "./setup.js"

beforeEach(() => {
  document.body.innerHTML = `<div id="terminal"><div data-terminal-output></div><input data-terminal-input></div>`
})

test("commands and clear reach the dock with a usable deduplicated history", () => {
  const {hook, events} = mountHook(Terminal, "#terminal")
  const input = hook.input()
  key(input, "ArrowUp")
  for (const command of ["pwd", "ls", "pwd"]) {
    input.value = command
    key(input,"Enter")
  }
  expect(events.map(e=>e.payload.command)).toEqual(["pwd","ls","pwd"])
  expect(events.every(event => event.target === hook.el)).toBe(true)
  expect(input.value).toBe("")
  key(input,"ArrowUp")
  expect(input.value).toBe("pwd")
  key(input,"ArrowUp")
  expect(input.value).toBe("ls")
  key(input,"ArrowDown")
  expect(input.value).toBe("pwd")
  key(input,"ArrowDown")
  expect(input.value).toBe("")
  key(input,"l",{ctrlKey:true})
  expect(events.at(-1)).toEqual({name:"clear",payload:{},target:hook.el})
  input.value = "typed draft"
  input.dispatchEvent(new Event("input",{bubbles:true}))
  expect(hook.cursor).toBeNull()
})

test("disabled and empty inputs cannot execute and finished commands regain focus", () => {
  const {hook, events} = mountHook(Terminal, "#terminal")
  const input = hook.input()
  key(input,"Enter")
  input.value = "rm never"
  input.disabled = true
  key(input,"Enter")
  expect(events).toHaveLength(0)
  hook.updated()
  input.disabled = false
  hook.updated()
  expect(document.activeElement).toBe(input)
})

test("output follows new lines until the reader scrolls up", () => {
  const {hook} = mountHook(Terminal, "#terminal")
  const output = hook.output()
  dimensions(output,{scrollHeight:1000,clientHeight:200})
  hook.updated()
  expect(output.scrollTop).toBe(1000)
  output.scrollTop = 200
  output.dispatchEvent(new Event("scroll"))
  dimensions(output,{scrollHeight:1200})
  hook.updated()
  expect(output.scrollTop).toBe(200)
  output.click()
  expect(document.activeElement).toBe(hook.input())
})

test("a busy fieldset prevents execution and releases focus when the command finishes", () => {
  document.body.innerHTML = `<div id="terminal"><fieldset disabled><div><input data-terminal-input></div></fieldset></div>`
  const {hook, events} = mountHook(Terminal, "#terminal")
  const input = hook.input()
  input.value = "echo unfinished"
  key(input, "Enter")
  hook.updated()
  expect(input.value).toBe("echo unfinished")
  expect(events).toHaveLength(0)
  input.closest("fieldset").disabled = false
  hook.updated()
  expect(document.activeElement).toBe(input)
  key(input, "Enter")
  expect(input.value).toBe("")
  expect(events).toEqual([{name: "exec", payload: {command: "echo unfinished"}, target: hook.el}])
})

test("Ctrl+` clicks the dock's New terminal item unless it is missing or disabled", () => {
  document.body.innerHTML += `<button id="dock-shell-new"></button>`
  const {hook} = mountHook(Terminal, "#terminal")
  const item = document.getElementById("dock-shell-new")
  let clicks = 0
  item.addEventListener("click", () => clicks++)
  const press = init => {
    const event = new KeyboardEvent("keydown", {key: "`", code: "Backquote", bubbles: true, cancelable: true, ...init})
    window.dispatchEvent(event)
    return event
  }
  let reached = 0
  const shell = document.createElement("textarea")
  document.body.append(shell)
  shell.addEventListener("keydown", () => reached++)
  const inShell = new KeyboardEvent("keydown", {key: "`", code: "Backquote", ctrlKey: true, bubbles: true, cancelable: true})
  shell.dispatchEvent(inShell)
  expect(inShell.defaultPrevented).toBe(true)
  expect(reached).toBe(0)
  expect(clicks).toBe(1)
  press({})
  press({ctrlKey: true, metaKey: true})
  press({ctrlKey: true, key: "a", code: "KeyA"})
  expect(clicks).toBe(1)
  item.disabled = true
  expect(press({ctrlKey: true}).defaultPrevented).toBe(false)
  item.remove()
  press({ctrlKey: true})
  expect(clicks).toBe(1)
  hook.destroyed()
  document.body.innerHTML += `<button id="dock-shell-new"></button>`
  document.getElementById("dock-shell-new").addEventListener("click", () => clicks++)
  press({ctrlKey: true})
  expect(clicks).toBe(1)
})

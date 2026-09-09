import {beforeEach, expect, test} from "bun:test"
import {Terminal} from "../js/hooks/terminal.js"
import {dimensions, key, mountHook} from "./setup.js"

beforeEach(() => {
  document.body.innerHTML = `<div id="terminal"><div data-terminal-output></div><input data-terminal-input></div>`
})

test("commands send once with a usable deduplicated history and clear shortcut", () => {
  const {hook, events} = mountHook(Terminal, "#terminal")
  const input = hook.input()
  key(input, "ArrowUp")
  for (const command of ["pwd", "ls", "pwd"]) {
    input.value = command
    key(input,"Enter")
  }
  expect(events.map(e=>e.payload.command)).toEqual(["pwd","ls","pwd"])
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
  expect(events.at(-1)).toEqual({name:"clear",payload:{}})
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

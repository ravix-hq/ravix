import {GlobalRegistrator} from "@happy-dom/global-registrator"
import {afterEach} from "bun:test"

GlobalRegistrator.register({url: "http://localhost:4000"})
// Import every hook so adding an untested hook cannot silently escape coverage.
for (const path of new Bun.Glob("*.js").scanSync({cwd: new URL("../js/hooks/", import.meta.url).pathname})) {
  await import(new URL(`../js/hooks/${path}`, import.meta.url).href)
}
const hooks = []

export function mountHook(definition, selector) {
  const events = []
  const handlers = new Map()
  const hook = {
    ...definition,
    el: document.querySelector(selector),
    pushEvent: (name, payload) => events.push({name, payload}),
    handleEvent: (name, handler) => handlers.set(name, handler),
  }
  hook.mounted()
  hooks.push(hook)
  return {hook, events, receive: (name, payload = {}) => handlers.get(name)(payload)}
}

export function dimensions(el, values) {
  for (const [key, value] of Object.entries(values)) {
    Object.defineProperty(el, key, {value, configurable: true})
  }
}

export function key(el, name, options = {}) {
  const event = new KeyboardEvent("keydown", {key: name, bubbles: true, cancelable: true, ...options})
  el.dispatchEvent(event)
  return event
}

afterEach(async () => {
  for (const hook of hooks.splice(0)) hook.destroyed?.()
  await window.happyDOM.abort()
  document.body.innerHTML = ""
  document.documentElement.removeAttribute("style")
  document.documentElement.removeAttribute("data-theme")
  localStorage.clear()
})

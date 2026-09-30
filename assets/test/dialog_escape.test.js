import {test, expect, afterEach} from "bun:test"
import {watchDialogs} from "../js/dialog_escape"

let dialogs
afterEach(() => {
  dialogs?.stop()
  document.body.innerHTML = ""
})

// What LiveView's keydown binding on window would add to its payload.
function press(key, target = document.body) {
  let meta
  const read = (e) => (meta = dialogs.keydown(e))
  window.addEventListener("keydown", read)
  target.dispatchEvent(new KeyboardEvent("keydown", {key, bubbles: true}))
  window.removeEventListener("keydown", read)
  return meta
}

test("an Escape pressed while a dialog is open says so", () => {
  dialogs = watchDialogs(window)
  expect(press("Escape")).toEqual({})
  document.body.innerHTML = `<div class="yard-scrim"></div><div id="d" class="scrim"><input id="q"></div>`
  expect(press("Escape")).toEqual({dialog: true})
  expect(press("Escape", document.getElementById("q"))).toEqual({dialog: true})
  expect(press("a")).toEqual({})
})

test("the note is taken before the dialog's own close hides it", () => {
  dialogs = watchDialogs(window)
  document.body.innerHTML = `<div id="d" class="scrim"></div>`
  // The dialog's binding runs first and hides the scrim; later bindings on
  // the same press still see that it was open.
  const close = (e) => { if (e.key === "Escape") document.getElementById("d").hidden = true }
  window.addEventListener("keydown", close)
  try {
    expect(press("Escape")).toEqual({dialog: true})
  } finally {
    window.removeEventListener("keydown", close)
  }
  // Closed and waiting for the server to remove it: not open any more.
  expect(press("Escape")).toEqual({})
})

test("stop removes the listener", () => {
  dialogs = watchDialogs(window)
  document.body.innerHTML = `<div class="scrim"></div>`
  dialogs.stop()
  expect(press("Escape")).toEqual({})
})

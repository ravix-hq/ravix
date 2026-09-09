import {beforeEach, expect, test} from "bun:test"
import {PanelResize} from "../js/hooks/panel_resize.js"
import {dimensions, key, mountHook} from "./setup.js"

beforeEach(() => {
  document.body.innerHTML = `<div class="app"><section><div id="handle" data-side="left" data-var="--yard-width" data-min="220" data-max="480" data-key="ravix.panel-width.left"></div></section></div>`
  dimensions(document.querySelector(".app"),{clientWidth:1400})
  dimensions(document.querySelector("section"),{clientWidth:300})
  document.querySelector("section").getBoundingClientRect = () => ({width:300})
})

test("keyboard resizing respects limits and persists accessible width", () => {
  const {hook} = mountHook(PanelResize,"#handle")
  key(hook.el,"Home")
  expect(hook.el.getAttribute("aria-valuenow")).toBe("220")
  key(hook.el,"ArrowRight")
  expect(localStorage.getItem("ravix.panel-width.left")).toBe("230")
  key(hook.el,"ArrowRight",{shiftKey:true})
  expect(hook.el.getAttribute("aria-valuenow")).toBe("280")
  key(hook.el,"ArrowLeft")
  expect(hook.el.getAttribute("aria-valuenow")).toBe("270")
  key(hook.el,"End")
  expect(hook.el.getAttribute("aria-valuenow")).toBe("480")
  expect(document.documentElement.style.getPropertyValue("--yard-width")).toBe("480px")
  expect(key(hook.el,"x").defaultPrevented).toBe(false)
})

test("right-hand panels reverse arrow direction and saved widths are restored", () => {
  const el = document.querySelector("#handle")
  el.dataset.side = "right"
  localStorage.setItem(el.dataset.key,"350")
  const {hook} = mountHook(PanelResize,"#handle")
  key(el,"Home")
  key(el,"ArrowLeft")
  expect(hook.width).toBe(230)
})

test("pointer dragging captures its pointer, ignores others, and cleans up on cancellation", () => {
  const {hook} = mountHook(PanelResize,"#handle")
  const captures = []
  hook.el.setPointerCapture = id=>captures.push(id)
  hook.el.releasePointerCapture = id=>captures.push(-id)
  hook.el.dispatchEvent(new PointerEvent("pointerdown",{pointerId:7,clientX:300,button:0,isPrimary:true}))
  hook.el.dispatchEvent(new PointerEvent("pointermove",{pointerId:8,clientX:900}))
  const width = hook.width
  hook.el.dispatchEvent(new PointerEvent("pointermove",{pointerId:7,clientX:340}))
  expect(hook.width).toBe(width+40)
  hook.el.dispatchEvent(new PointerEvent("pointerup",{pointerId:7}))
  expect(captures).toEqual([7,-7])
  expect(hook.el.dataset.dragging).toBe("false")
  hook.el.dispatchEvent(new PointerEvent("pointercancel"))
  hook.el.dispatchEvent(new PointerEvent("lostpointercapture"))
  expect(hook.drag).toBeNull()
})

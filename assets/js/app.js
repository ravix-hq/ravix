// The whole of the JavaScript in the product.
//
// Ravix is a LiveView application: the server renders every page and every
// change to it, and the browser's job is to keep the socket up and to do the
// handful of things that cannot round-trip — a keystroke in the terminal, a
// scroll position, a drag, the palette painted before the first frame. Those
// live in `hooks/`, one file each, and this file registers them. There is
// nothing else: no framework, no state, no packages beyond Phoenix's own.
//
// The six hooks, and what they are for:
//
//   Theme           the palette picker (reads and writes `ravix.theme`)
//   PanelResize     the drag handle between the rail, the stage and the inspector
//   TranscriptTail  a scrollback that follows new output while you are at the bottom
//   Composer        the prompt box: Enter sends, pasted images become uploads
//   Terminal        the shell panel: history, Ctrl+L, output that follows itself
//   Notify          desktop notifications when a track needs you and you are not looking
//
// Adding a seventh is a product decision, not a convenience. Say why in its
// file's header, and list it here.
import "../css/app.css"
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {Theme} from "./hooks/theme"
import {PanelResize} from "./hooks/panel_resize"
import {TranscriptTail} from "./hooks/transcript_tail"
import {Composer} from "./hooks/composer"
import {Terminal} from "./hooks/terminal"
import {Notify} from "./hooks/notify"

const hooks = {Theme, PanelResize, TranscriptTail, Composer, Terminal, Notify}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks,
})

liveSocket.connect()

// For the console: `liveSocket.enableDebug()`, `liveSocket.enableLatencySim(1000)`.
window.liveSocket = liveSocket

// Development only: server logs in the console, and click-to-open on
// components (hold `c` for the caller, `d` for the definition).
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
    let keyDown
    window.addEventListener("keydown", e => (keyDown = e.key))
    window.addEventListener("keyup", _e => (keyDown = null))
    window.addEventListener(
      "click",
      e => {
        if (keyDown === "c") {
          e.preventDefault()
          e.stopImmediatePropagation()
          reloader.openEditorAtCaller(e.target)
        } else if (keyDown === "d") {
          e.preventDefault()
          e.stopImmediatePropagation()
          reloader.openEditorAtDef(e.target)
        }
      },
      true,
    )
    window.liveReloader = reloader
  })
}

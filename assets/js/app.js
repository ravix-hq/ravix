// The whole of the JavaScript in the product.
//
// Ravix is a LiveView application: the server renders every page and every
// change to it, and the browser's job is to keep the socket up and to do the
// handful of things that cannot round-trip — a keystroke in the terminal, a
// scroll position, a drag, the palette painted before the first frame. Those
// live in `hooks/`, one file each, and this file registers them. The
// page_loading helper also reflects pending navigation in the shared status
// indicator. There is no framework or package beyond Phoenix's own.
//
// The hooks, and what they are for:
//
//   Theme           the palette picker (reads and writes `ravix.theme`)
//   PanelResize     the drag handle between the rail, the stage and the inspector
//   TranscriptTail  a scrollback that follows new output while you are at the bottom
//   Composer        the prompt box: Enter sends, pasted images become uploads
//   Terminal        the shell panel: history, Ctrl+L, output that follows itself
//   Notify          desktop notifications when a track needs you and you are not looking
//   SettingsSections section navigation and unsaved input warnings
//   TrackTabs       horizontal scrolling and selected track visibility
//   ProjectSections drag a sidebar project onto one of your sections
//
// Adding a hook is a product decision, not a convenience. Say why in its
// file's header, and list it here.
import "../css/app.css"
import "phoenix_html"
import {trackPageLoading} from "./page_loading"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {Theme} from "./hooks/theme"
import {PanelResize} from "./hooks/panel_resize"
import {TranscriptTail} from "./hooks/transcript_tail"
import {Composer} from "./hooks/composer"
import {Terminal} from "./hooks/terminal"
import {Notify} from "./hooks/notify"
import {TrackTabs} from "./hooks/track_tabs"
import {SettingsSections} from "./hooks/settings_sections"
import {ProjectSections} from "./hooks/project_sections"

const hooks = {Theme, PanelResize, TranscriptTail, Composer, Terminal, Notify, SettingsSections, TrackTabs, ProjectSections}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks,
})

trackPageLoading(window)
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

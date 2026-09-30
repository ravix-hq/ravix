// The whole of the JavaScript in the product.
//
// Ravix is a LiveView application: the server renders every page and every
// change to it, and the browser's job is to keep the socket up and to do the
// handful of things that cannot round-trip — a keystroke in the terminal, a
// scroll position, a drag, the palette painted before the first frame. Those
// live in `hooks/`, one file each, and this file registers them. The
// page_loading helper also reflects pending navigation in the shared status
// indicator, dialog_escape tells a keydown whether a dialog was open, and the
// connect params carry the browser's time zone. There is
// no framework, and one library beyond Phoenix's own:
// xterm.js, vendored, which is its own bundle (`xterm.js`) loaded by the Shell
// hook the first time a terminal is opened, so it costs this file nothing.
//
// The hooks, and what they are for:
//
//   ThreadTabs      keyboard navigation and overflow visibility for conversation threads
//   Theme           the palette picker (reads and writes `ravix.theme`)
//   PanelResize     the drag handle between the rail, the stage and the inspector
//   PanelToggle     whether those sidebars are open; a preference of this browser
//   TranscriptTail  a scrollback that follows new output while you are at the bottom
//   Composer        the prompt box: Enter sends, pasted images become uploads
//   Terminal        the Commands panel: history, Ctrl+L, output that follows itself
//   Shell           an interactive terminal tab: xterm.js over the page's socket
//   Notify          desktop notifications when a track needs you and you are not looking
//   NotifyToggle    the switch for them, on the Notifications settings page
//   SettingsSections a project settings section's own Save, Discard and agent choice
//   UnsavedChanges  a settings page's unsaved-changes bar and leave confirmation
//   SettingsFrame   a settings page opens each section at its top
//   ProjectTree     viewer-local collapse preferences for project and section rows
//   QuickJump       Cmd/Ctrl-K, Cmd/Ctrl-N and keyboard selection in navigation search
//   QuickJumpQuery  search's query: focused as it mounts, with the keys typed on the way
//   ProjectSections drag a sidebar project onto one of your sections
//   ProjectFormFocus synchronous dialog focus that never steals later typing
//   CopyCode        copy a Help example exactly, with success or failure feedback
//   TurnTimer       a running turn's elapsed time, ticking without a round-trip
//   RelativeTime    a sidebar row's "22h" age, kept current without server ticks
//   LocalTime       a timestamp in the viewer's own zone and locale
//   SubmitOnEnter   the create dialog's first prompt: Enter creates, Shift+Enter is a new line
//   HeaderFit       a track header's status chips: whole words or just their icons
//   ChipMenu        a chip's popover: aria-expanded, Escape and focus return inside a dialog
//
// Adding a hook is a product decision, not a convenience. Say why in its
// file's header, and list it here.
import "../css/app.css"
import "phoenix_html"
import {clearTransportFallback, LONG_POLL_FALLBACK_MS} from "./transport"
import {trackPageLoading} from "./page_loading"
import {watchDialogs} from "./dialog_escape"
import {browserTimeZone} from "./timezone"
import {macPlatform} from "./platform"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {ThreadTabs} from "./hooks/thread_tabs"
import {Theme} from "./hooks/theme"
import {PanelResize} from "./hooks/panel_resize"
import {PanelToggle} from "./hooks/panel_toggle"
import {TranscriptTail} from "./hooks/transcript_tail"
import {Composer} from "./hooks/composer"
import {Terminal} from "./hooks/terminal"
import {Shell} from "./hooks/shell"
import {Notify, NotifyToggle} from "./hooks/notify"
import {ProjectTree} from "./hooks/project_tree"
import {QuickJump, QuickJumpQuery} from "./hooks/quick_jump"
import {AgentConfirmation} from "./hooks/agent_confirmation"
import {SettingsSections} from "./hooks/settings_sections"
import {UnsavedChanges} from "./hooks/unsaved_changes"
import {SettingsFrame} from "./hooks/settings_frame"
import {ProjectSections} from "./hooks/project_sections"
import {ProjectFormFocus} from "./hooks/project_form_focus"
import {CopyCode} from "./hooks/copy_code"
import {ShareMention} from "./hooks/share_mention"
import {TurnTimer} from "./hooks/turn_timer"
import {RelativeTime} from "./hooks/relative_time"
import {LocalTime} from "./hooks/local_time"
import {SubmitOnEnter} from "./hooks/submit_on_enter"
import {HeaderFit} from "./hooks/header_fit"
import {ChipMenu} from "./hooks/chip_menu"



const hooks = {ThreadTabs, AgentConfirmation, Theme, PanelResize, PanelToggle, TranscriptTail, Composer, Terminal, Notify, NotifyToggle, SettingsSections, UnsavedChanges, SettingsFrame, ProjectTree, QuickJump, QuickJumpQuery, ProjectSections, CopyCode, ProjectFormFocus, ShareMention, TurnTimer, RelativeTime, SubmitOnEnter, Shell, HeaderFit, LocalTime, ChipMenu}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
clearTransportFallback(window)
const dialogs = watchDialogs(window)
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: LONG_POLL_FALLBACK_MS,
  params: {_csrf_token: csrfToken, timezone: browserTimeZone(), platform: macPlatform() ? "mac" : "other"},
  hooks,
  metadata: {keydown: dialogs.keydown},
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

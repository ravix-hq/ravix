// Desktop notifications: a track that has come to need somebody, said by
// the operating system while this tab is not the one being looked at.
//
// The sixth hook, and why it is one. The product's promise is that you can
// close the laptop while the agent works, and until now the only way to
// learn it had finished was to come back and look at the inbox badge. The
// Notification API is the browser's, its permission can only be asked for
// from a click, and whether this tab is in the background is something
// only the browser knows; none of that can round-trip.
//
// The division of labour is strict. The server owns the news:
// `RavixWeb.WorkspaceLive` diffs the rail itself and sends a `notify`
// event naming the tracks that have *just* come to need somebody, so a
// rail redrawn on a reload says nothing and a track is said once. This
// file owns whether to show it: whether the person switched it on (kept
// in localStorage under `ravix.notify`, a preference like the theme),
// whether the browser has allowed it, and whether this tab is the one they
// are looking at, in which case the inbox badge is already saying it.
//
// Clicking a notification does not navigate from here. It focuses the
// window and asks the server to open the track (`open-notice`), which
// checks the track against what this person can see before patching the
// URL, the same as any link in the rail.
//
// Two hooks, because the switch is in two places (RAV-77). `Notify` is the
// You menu's quick toggle, in the app shell, so it also hears every
// `notify` event whichever page is open; `NotifyToggle` is the same switch
// on the Notifications settings page, without the news. They share
// localStorage and the browser's permission, both read fresh each time,
// and a change in one is announced on the window (`CHANGED`) so the other
// redraws at once. What each expects:
//
//   <div id="notify" phx-hook="Notify" class="notify">
//     <button data-notify-toggle aria-pressed="false">
//       <span data-notify-dot></span>
//       <span class="col"><small>Desktop notifications</small><span data-notify-state></span></span>
//     </button>
//   </div>
//
// The four states the button can show, and the label for each, are in
// `LABELS`. "Blocked" is the browser's answer, not ours: once a site is
// denied, only the browser's own settings can change that, so the button
// says so rather than asking again to no effect.

export const NOTIFY_KEY = "ravix.notify"
const CHANGED = "ravix:notify-changed"

const LABELS = {
  on: "On",
  off: "Off",
  blocked: "Blocked in this browser",
  unsupported: "Not available in this browser",
}

function supported() {
  return typeof Notification === "function"
}

function readSaved() {
  try {
    return localStorage.getItem(NOTIFY_KEY)
  } catch {
    // A private window, or site data switched off: off is a complete answer.
    return null
  }
}

function remember(value) {
  try {
    localStorage.setItem(NOTIFY_KEY, value)
  } catch {
    // It still applies to this page; it just will not be remembered.
  }
}

// Whether the person is looking somewhere else: a hidden tab, or a visible
// one in a window that does not have focus. Either way the badge in the
// rail is not being seen, which is the whole reason to say it out loud.
function away() {
  if (document.hidden === true) return true
  return typeof document.hasFocus === "function" && !document.hasFocus()
}

function body(track) {
  const where = track.project ? ` in ${track.project}` : ""
  if (track.status === "failed") return `The agent hit a problem${where}.`
  if (track.mention) return `@${track.mention} mentioned you${where}.`
  return `The agent finished${where}.`
}

// What the switch is showing. "On" needs both the person's yes and the
// browser's: a saved preference outlives a permission the browser reset.
export function notifyState() {
  if (!supported()) return "unsupported"
  if (Notification.permission === "denied") return "blocked"
  return readSaved() === "on" && Notification.permission === "granted" ? "on" : "off"
}

// Returns the promise so a test can wait for the browser's answer; the
// click handlers do not need it.
export function toggleNotify() {
  const state = notifyState()
  if (state === "unsupported" || state === "blocked") return Promise.resolve()
  if (state === "on") {
    remember("off")
    announce()
    return Promise.resolve()
  }
  // Asked from a click, which is the only place a browser will listen.
  return Promise.resolve(Notification.requestPermission()).then(permission => {
    remember(permission === "granted" ? "on" : "off")
    announce()
  })
}

function announce() {
  window.dispatchEvent(new CustomEvent(CHANGED))
}

function reflect(el) {
  const state = notifyState()
  const label = el.querySelector("[data-notify-state]")
  if (label) label.textContent = LABELS[state]
  const button = el.querySelector("[data-notify-toggle]")
  if (button) {
    button.setAttribute("aria-pressed", state === "on" ? "true" : "false")
    button.disabled = state === "unsupported" || state === "blocked"
  }
  el.classList.toggle("on", state === "on")
  el.classList.toggle("blocked", state === "blocked")
}

// The switch's half, shared by both hooks: a click on it asks, and the
// markup says the answer.
const Switch = {
  mounted() {
    this.onClick = e => {
      if (e.target.closest("[data-notify-toggle]")) this.toggle()
    }
    this.onChanged = () => this.reflect()
    this.el.addEventListener("click", this.onClick)
    window.addEventListener(CHANGED, this.onChanged)
    this.reflect()
  },

  updated() {
    // A patch from the server re-renders the label without the client's
    // state on it; put it back.
    this.reflect()
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener(CHANGED, this.onChanged)
  },

  state() {
    return notifyState()
  },

  // Redrawn by the announcement, this switch included.
  toggle() {
    return toggleNotify()
  },

  reflect() {
    reflect(this.el)
  },
}

export const NotifyToggle = Switch

export const Notify = {
  ...Switch,

  mounted() {
    Switch.mounted.call(this)
    this.handleEvent("notify", ({tracks}) => this.show(tracks || []))
  },

  show(tracks) {
    if (this.state() !== "on" || !away()) return
    for (const track of tracks) {
      let notification
      try {
        // One per thread: a second tab announcing the same track replaces
        // this one rather than stacking beside it.
        notification = new Notification(track.title, {body: body(track), tag: `ravix-thread-${track.thread_id}`})
      } catch {
        // Some mobile browsers only notify through a service worker and
        // throw here. There is nothing to show, and nothing to say about it.
        continue
      }
      notification.onclick = () => {
        window.focus()
        this.pushEvent("open-notice", {track: track.id, thread: track.thread_id})
        notification.close()
      }
    }
  },
}

import {macPlatform} from "../platform"

// Quick jump (RAV-99). ⌘K on a Mac and Ctrl+K elsewhere open search from
// anywhere on the page, a field included, through the visible dialog trigger,
// as Cmd/Ctrl-N does New track's. Two places keep the key: a terminal, whose
// shell owns Ctrl+K, and another open dialog. Arrow keys move through native
// navigation links, in search and in any `data-jump-scope` list; Enter in its
// query takes the first, Escape is the dialog's own close.
//
// Opening is a round trip, and people type the moment they press the key. So
// from the trigger's click until the query field mounts, printable keys are
// held here rather than landing on the focused trigger, where Space or Enter
// would press it again, and `QuickJumpQuery` hands them to the field as it
// mounts: no keystroke is lost.
let held = null
const HOLD_MS = 3000

function hold() {
  clearTimeout(held?.timer)
  // A dialog that never opens (a lost socket) must not swallow the page's keys.
  held = {keys: "", timer: setTimeout(() => { held = null }, HOLD_MS)}
}

function release() {
  const keys = held?.keys || ""
  clearTimeout(held?.timer)
  held = null
  return keys
}

const typed = event => event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey && !event.isComposing

// Another modal is open: the search dialog itself, or anything else drawn
// over the page. A closing dialog is `hidden` until the server removes it.
const openModal = () => [...document.querySelectorAll('.scrim')].find(scrim => !scrim.hidden) ||
  document.querySelector('dialog[open]')

export const QuickJump = {
  mounted() {
    const mac = macPlatform()
    // Capture, so held keys never reach the element that has focus.
    this.onHeld = event => {
      if (!held || document.getElementById('search-query')) return
      if (event.key === 'Escape') { release(); return }
      if (typed(event)) held.keys += event.key
      else if (event.key === 'Backspace') held.keys = held.keys.slice(0, -1)
      else if (event.key !== 'Enter') return
      event.preventDefault()
      event.stopPropagation()
    }
    this.onClick = event => { if (event.target.closest?.('[data-quick-jump-trigger]')) hold() }
    this.onKey = event => {
      const modifier = mac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey
      if (modifier && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'k') {
        if (event.target.closest?.('.xterm, [phx-hook="Terminal"]')) return
        const modal = openModal()
        if (modal) {
          // Pressed again in search, it goes back to the query.
          const query = modal.id === 'search-dialog' && document.getElementById('search-query')
          if (query) {
            event.preventDefault()
            query.focus()
            query.select()
          }
          return
        }
        const trigger = [...this.el.querySelectorAll('[data-quick-jump-trigger]')]
          .find(button => button.getClientRects().length > 0)
        if (trigger) {
          event.preventDefault()
          trigger.focus()
          trigger.click()
        }
        return
      }
      // Cmd/Ctrl-N opens New track the way Cmd/Ctrl-K opens search, from a
      // field too. It gives way to the browser's own new window wherever it
      // cannot help: Chrome and Edge keep the key in an ordinary tab and never
      // deliver it (an installed app window does), a terminal keeps it for
      // its shell, an open dialog keeps it, and with no visible New track
      // button it is not taken. Shift and Alt variants are never taken.
      if (modifier && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'n') {
        if (event.target.closest?.('.xterm')) return
        if (this.el.querySelector('[role="dialog"]')) return
        const trigger = [...this.el.querySelectorAll('[data-new-track-trigger]')]
          .find(button => button.getClientRects().length > 0 && !button.disabled)
        if (trigger) {
          event.preventDefault()
          trigger.focus()
          trigger.click()
        }
        return
      }
      // Typing on a highlighted result goes on typing in the query.
      const query = document.getElementById('search-query')
      if (query && typed(event) && event.target.matches?.('#search-dialog [data-jump-result]')) {
        query.focus()
        return
      }
      // Search, and any other list that asks for the same keys by marking
      // itself `data-jump-scope` (the New track repository list).
      const dialog = this.el.querySelector('#search-dialog')
      const scope = dialog?.contains(event.target) ? dialog : event.target.closest?.('[data-jump-scope]')
      if (!scope || !this.el.contains(scope)) return
      const results = [...scope.querySelectorAll('[data-jump-result]')].filter(result => !result.disabled)
      if (!results.length) return
      const index = results.indexOf(document.activeElement)
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault()
        const next = index < 0 ? (event.key === 'ArrowDown' ? 0 : results.length - 1)
          : (index + (event.key === 'ArrowDown' ? 1 : -1) + results.length) % results.length
        results[next].focus()
      } else if (event.key === 'Enter' && (event.target.id === 'search-query' || event.target.matches?.('[data-jump-query]'))) {
        event.preventDefault()
        results[0].click()
      }
    }
    window.addEventListener('keydown', this.onHeld, true)
    window.addEventListener('keydown', this.onKey)
    this.el.addEventListener('click', this.onClick, true)
  },
  beforeUpdate() {
    const active = document.activeElement
    this.focusedLink = this.el.contains(active) && active.matches('[data-jump-result][id]') ? active.id : null
  },
  updated() {
    // Filtering can move a selected row. Restore lost focus without overriding
    // a field or another result the person selected while the response arrived.
    const link = this.focusedLink && document.getElementById(this.focusedLink)
    this.focusedLink = null
    if (document.activeElement === document.body && link && this.el.contains(link)) link.focus({preventScroll: true})
  },
  destroyed() {
    release()
    window.removeEventListener('keydown', this.onHeld, true)
    window.removeEventListener('keydown', this.onKey)
    this.el.removeEventListener('click', this.onClick, true)
  },
}

// The search query field. It takes focus as it mounts, in the same patch that
// draws the dialog, and appends whatever was typed on the way; the `input`
// event it raises is the form's phx-change, so the results follow.
export const QuickJumpQuery = {
  mounted() {
    const keys = release()
    this.el.focus()
    if (keys) {
      this.el.value += keys
      this.el.dispatchEvent(new Event('input', {bubbles: true}))
    }
    const end = this.el.value.length
    this.el.setSelectionRange?.(end, end)
  },
}

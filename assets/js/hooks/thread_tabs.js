// Manual-activation tabs: arrow keys move the one tab stop; Enter/Space
// selects through LiveView. Background activity must not reset overflow scroll.
//
// RAV-97: the tablist scrolls on its own, and `data-overflow` on the strip
// says which of its ends ("start", "end") has tabs out of sight, for the edge
// fades and the ‹ › that scroll it. A double-click or F2 on a tab asks to
// rename it (`data-can-rename`); the server then lays a field over the tab.
// In that field Escape cancels and leaving it saves; either way focus goes
// back to the tab. Delete on a tab closes its thread (`data-can-close`), or
// discards the draft. ⌘T (Ctrl+T off a Mac) asks for a new thread wherever
// the browser lets a page have it, and the "+" menu's hint says whichever.
import {macPlatform} from "../platform"

export const ThreadTabs = {
  mounted() {
    this.list = () => this.el.querySelector('.thread-tablist')
    this.focusTab = tab => {
      this.el.querySelectorAll('.thread-tab').forEach(item => { item.tabIndex = item === tab ? 0 : -1 })
    }
    this.focusin = event => {
      if (event.target.matches('.thread-tab')) this.focusTab(event.target)
    }
    this.rename = tab => {
      if (!tab || !this.el.hasAttribute('data-can-rename') || tab.dataset.threadId === 'draft') return
      this.pushEvent('edit-thread-title', {thread_id: tab.dataset.threadId})
    }
    this.keydown = event => {
      if (event.target.id === 'thread-rename-input') {
        if (event.key === 'Escape') {
          event.preventDefault()
          event.stopPropagation()
          this.cancelled = true
          this.pushEvent('cancel-thread-rename', {})
        }
        return
      }
      const tabs = [...this.el.querySelectorAll('.thread-tab')]
      const index = tabs.indexOf(event.target)
      if (index < 0 || event.altKey || event.ctrlKey || event.metaKey) return
      if (event.key === 'F2') {
        event.preventDefault()
        this.rename(event.target)
        return
      }
      if (event.key === 'Delete') {
        event.preventDefault()
        this.close(event.target)
        return
      }
      // The list stands on end beside the conversation, and lies across the
      // top on a phone, so both pairs of arrows move through it.
      const forward = (index + 1) % tabs.length
      const back = (index + tabs.length - 1) % tabs.length
      const next = new Map([['ArrowRight', forward], ['ArrowDown', forward],
        ['ArrowLeft', back], ['ArrowUp', back],
        ['Home', 0], ['End', tabs.length - 1]]).get(event.key)
      if (next === undefined) return
      event.preventDefault()
      tabs[next].focus()
      tabs[next].scrollIntoView({block: 'nearest', inline: 'nearest'})
    }
    // Selecting on the first click can move the tab (its unread dot goes),
    // so the second may land beside it: the tab is the one first pressed.
    this.mousedown = event => {
      if (event.detail <= 1) this.pressed = event.target.closest?.('.thread-tab')
    }
    this.dblclick = event => {
      if (event.target.closest?.('.thread-tab-action')) return
      this.rename(event.target.closest?.('.thread-tab') || this.pressed)
    }
    this.close = tab => {
      if (tab.dataset.threadId === 'draft') this.pushEvent('discard-draft', {})
      else if (this.el.hasAttribute('data-can-close')) this.pushEvent('close-thread', {thread_id: tab.dataset.threadId})
    }
    // ‹ › move the tablist by most of its width.
    this.scroll = event => {
      const button = event.target.closest?.('[data-scroll]')
      const list = this.list()
      if (!button || !list) return
      list.scrollBy({left: Number(button.dataset.scroll) * list.clientWidth * 0.8, behavior: 'smooth'})
    }
    this.mac = macPlatform()
    this.shortcut = event => {
      const mod = this.mac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey
      if (!mod || event.altKey || event.shiftKey || event.key?.toLowerCase() !== 't') return
      const add = this.el.querySelector('#thread-add-trigger')
      if (!add || add.disabled) return
      event.preventDefault()
      this.pushEvent('draft-thread', {})
    }
    const hint = this.el.querySelector('[data-shortcut="t"]')
    if (hint) hint.textContent = this.mac ? '⌘T' : 'Ctrl+T'
    // Leaving the field saves what it holds; the server ignores a save for a
    // rename that Enter or Escape has already ended.
    this.focusout = event => {
      const input = event.target
      if (input.id !== 'thread-rename-input' || this.cancelled) return
      this.pushEvent('rename-thread', {thread_id: input.form.dataset.threadId, title: input.value})
    }
    this.reveal = (tab = this.el.querySelector('.thread-tab[aria-selected="true"]')) => {
      const list = this.list()
      if (!tab || !list) return
      const box = list.getBoundingClientRect()
      const at = tab.getBoundingClientRect()
      if (at.left < box.left) list.scrollLeft -= box.left - at.left
      else if (at.right > box.right) list.scrollLeft += at.right - box.right
    }
    this.overflow = () => {
      const list = this.list()
      if (!list) return
      const ends = []
      if (list.scrollLeft > 1) ends.push('start')
      if (list.scrollLeft + list.clientWidth < list.scrollWidth - 1) ends.push('end')
      if (ends.length) this.el.setAttribute('data-overflow', ends.join(' '))
      else this.el.removeAttribute('data-overflow')
    }
    this.el.addEventListener('keydown', this.keydown)
    this.el.addEventListener('focusin', this.focusin)
    this.el.addEventListener('focusout', this.focusout)
    this.el.addEventListener('dblclick', this.dblclick)
    this.el.addEventListener('mousedown', this.mousedown)
    this.el.addEventListener('click', this.scroll)
    window.addEventListener('keydown', this.shortcut)
    this.list()?.addEventListener('scroll', this.overflow, {passive: true})
    if (typeof ResizeObserver !== 'undefined') {
      // A narrower row keeps the selected tab in sight. This moves the
      // tablist alone: `scrollIntoView` would scroll every ancestor too, and
      // shift what the terminal below has measured itself against.
      this.resize = new ResizeObserver(() => {
        this.reveal()
        this.overflow()
      })
      this.resize.observe(this.el)
      if (this.list()) this.resize.observe(this.list())
    }
    this.updated()
  },
  updated() {
    const selected = this.el.querySelector('.thread-tab[aria-selected="true"]')
    const focused = this.el.querySelector('.thread-tab:focus')
    this.focusTab(focused || selected)
    if (selected?.id !== this.selectedId) {
      selected?.scrollIntoView({block: 'nearest', inline: 'nearest'})
      this.selectedId = selected?.id
    }
    const renaming = this.el.dataset.renaming
    const input = this.el.querySelector('#thread-rename-input')
    if (renaming && input && renaming !== this.renamingId) {
      this.cancelled = false
      this.reveal(document.getElementById(`thread-tab-${renaming}`))
      input.focus()
      input.select()
    } else if (!renaming && this.renamingId) {
      const active = document.activeElement
      if (!active || active === document.body || this.el.contains(active)) {
        document.getElementById(`thread-tab-${this.renamingId}`)?.focus()
      }
    }
    this.renamingId = renaming
    this.overflow()
  },
  destroyed() {
    this.el.removeEventListener('keydown', this.keydown)
    this.el.removeEventListener('focusin', this.focusin)
    this.el.removeEventListener('focusout', this.focusout)
    this.el.removeEventListener('dblclick', this.dblclick)
    this.el.removeEventListener('mousedown', this.mousedown)
    this.el.removeEventListener('click', this.scroll)
    window.removeEventListener('keydown', this.shortcut)
    this.resize?.disconnect()
  },
}

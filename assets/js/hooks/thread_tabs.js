// Manual-activation tabs: arrow keys move the one tab stop; Enter/Space
// selects through LiveView. Background activity must not reset overflow scroll.
//
// RAV-97: the tablist scrolls on its own, and `data-overflow` on the strip
// says which of its ends ("start", "end") has tabs out of sight, for the edge
// fades and the All threads menu. A double-click or F2 on a tab asks to
// rename it (`data-can-rename`); the server then lays a field over the tab.
// In that field Escape cancels and leaving it saves; either way focus goes
// back to the tab.
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
      const next = new Map([['ArrowRight', (index + 1) % tabs.length],
        ['ArrowLeft', (index + tabs.length - 1) % tabs.length],
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
    this.dblclick = event => this.rename(event.target.closest?.('.thread-tab') || this.pressed)
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
    this.resize?.disconnect()
  },
}

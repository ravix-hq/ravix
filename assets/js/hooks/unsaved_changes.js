// A settings page's unsaved changes (RAV-72): the sticky bar, and asking
// before leaving. One boolean, dirty or not; never a copy of a value.
//
// Dirty: input in a form inside, outside [data-unsaved-ignore], or an
// `unsaved:dirty` event from another hook. Clean: the server bumps
// data-saved, a form inside resets, or `unsaved:clean`.
//
// Leaving is a click on a link (LiveView's patch and navigate links are
// links too) or on [data-leaves-page], caught before LiveView sees it, and
// the tab closing or reloading. Browser back and forward are LiveView's
// popstate and are not asked about.
const LEAVE = 'a[href], [data-leaves-page]'

export const UnsavedChanges = {
  mounted() {
    this.dirty = false
    this.saved = this.el.dataset.saved
    this.pending = null
    this.dialog = this.el.querySelector('[data-unsaved-leave]')

    this.onInput = event => {
      if (!event.target.closest('form') || event.target.closest('[data-unsaved-ignore]')) return
      if (this.dialog?.contains(event.target)) return
      this.mark(true)
    }
    this.onReset = event => {
      if (!event.target.closest('[data-unsaved-ignore]')) this.mark(false)
    }
    this.onDirty = () => this.mark(true)
    this.onClean = () => this.mark(false)
    this.onClick = event => this.click(event)
    this.onKey = event => {
      if (event.key === 'Escape' && this.asking()) {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.stay()
      }
    }
    this.onUnload = event => {
      if (!this.dirty) return
      event.preventDefault()
      event.returnValue = ''
    }

    this.el.addEventListener('input', this.onInput)
    this.el.addEventListener('change', this.onInput)
    this.el.addEventListener('reset', this.onReset, true)
    this.el.addEventListener('unsaved:dirty', this.onDirty)
    this.el.addEventListener('unsaved:clean', this.onClean)
    document.addEventListener('click', this.onClick, true)
    window.addEventListener('keydown', this.onKey, true)
    window.addEventListener('beforeunload', this.onUnload)
  },

  updated() {
    if (this.el.dataset.saved !== this.saved) {
      this.saved = this.el.dataset.saved
      this.dirty = false
    }
    this.show()
  },

  destroyed() {
    document.removeEventListener('click', this.onClick, true)
    window.removeEventListener('keydown', this.onKey, true)
    window.removeEventListener('beforeunload', this.onUnload)
  },

  click(event) {
    const target = event.target
    if (this.el.contains(target)) {
      if (target.closest('[data-unsaved-discard]')) return this.discard()
      if (target.closest('[data-unsaved-stay]')) return this.stay()
      if (target.closest('[data-unsaved-confirm]')) return this.leave()
    }
    if (!this.dirty || this.asking()) return
    const link = target.closest(LEAVE)
    if (!link || !this.leaves(link, event)) return
    event.preventDefault()
    event.stopImmediatePropagation()
    // A menu item that would leave (the switcher's) shuts its menu, or the
    // menu would sit over the question in the top layer.
    link.closest('[popover]')?.hidePopover?.()
    this.pending = link
    this.dialog.hidden = false
    this.dialog.querySelector('[data-unsaved-stay]').focus()
  },

  // A link that opens elsewhere, or only moves within the page, leaves
  // nothing behind; so do the bar's own buttons.
  leaves(link, event) {
    if (link.closest('[data-unsaved-bar]')) return false
    if (link.matches('[data-leaves-page]')) return true
    const href = link.getAttribute('href')
    if (!href || href.startsWith('#') || link.target === '_blank' || link.hasAttribute('download')) return false
    return !(event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button > 0)
  },

  asking() {
    return this.dialog && !this.dialog.hidden
  },

  stay() {
    const link = this.pending
    this.pending = null
    this.dialog.hidden = true
    if (link?.isConnected) link.focus()
  },

  leave() {
    const link = this.pending
    this.pending = null
    this.dialog.hidden = true
    this.discard()
    if (link?.isConnected) link.click()
  },

  discard() {
    this.el.querySelectorAll('form').forEach(form => {
      if (!form.closest('[data-unsaved-ignore]')) form.reset()
    })
    this.el.querySelectorAll('input[type="password"]').forEach(input => { input.value = '' })
    const event = this.el.dataset.discardEvent
    if (event) {
      const target = this.el.dataset.discardTarget
      if (target) this.pushEventTo(target, event, {})
      else this.pushEvent(event, {})
    }
    this.mark(false)
  },

  mark(dirty) {
    this.dirty = dirty
    this.show()
  },

  // The server's render drops attributes it did not write, so the state is
  // put back after every patch as well as on every change.
  show() {
    this.el.toggleAttribute('data-dirty', this.dirty)
    const bar = this.el.querySelector('[data-unsaved-bar]')
    if (bar) bar.hidden = !this.dirty
  },
}

// A chip and its native popover (`RavixWeb.Live.ModelMenu.chip/1`). The
// popover brings light dismiss and the top layer; this adds the rest of a
// menu button: `aria-expanded` on the chip, ArrowDown/ArrowUp on the chip to
// open it, focus into the popover when it opens and back to the chip when it
// closes, and an Escape that closes only the popover — the dialog around it
// listens for Escape on the window, so the key stops here. Picking an item
// marked `data-chip-close` closes the popover: a button on any activation, a
// radio on a pointer click or Enter, since arrow keys move a radio group's
// choice without being done with it.
export const ChipMenu = {
  mounted() {
    this.trigger = this.el.querySelector(':scope > [popovertarget]')
    this.menu = this.el.querySelector(':scope > [popover]')
    this.open = false
    this.onToggle = event => {
      this.open = event.newState === 'open'
      this.trigger.setAttribute('aria-expanded', String(this.open))
      if (this.open) {
        this.first()?.focus()
      } else {
        const active = document.activeElement
        if (!active || active === document.body || this.menu.contains(active)) this.trigger.focus()
      }
    }
    this.onEscape = event => {
      if (event.key !== 'Escape' || !this.open) return
      event.preventDefault()
      event.stopImmediatePropagation()
      this.close()
    }
    this.onTriggerKey = event => {
      if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && !this.open && !this.trigger.disabled) {
        event.preventDefault()
        this.menu.showPopover()
      }
    }
    this.onMenuKey = event => {
      // Enter on a radio would submit the form it belongs to; here it means
      // "this one".
      if (event.key === 'Enter' && event.target.matches('input[type=radio]')) {
        event.preventDefault()
        if (event.target.matches('[data-chip-close]')) this.close()
      }
    }
    this.onClick = event => {
      // A click on a radio's label is a pointer's; the click the label then
      // forwards to its radio, like Space's, has no `detail`.
      const label = event.target.closest?.('label')
      const item = event.target.closest?.('[data-chip-close]') ||
        (label && !event.target.matches('input') ? label.control : null)
      if (!item?.matches('[data-chip-close]') || !this.menu.contains(item) || item.disabled) return
      if (item === event.target && item.matches('input[type=radio]') && event.detail === 0) return
      this.close()
    }
    this.menu.addEventListener('toggle', this.onToggle)
    this.menu.addEventListener('keydown', this.onMenuKey)
    this.menu.addEventListener('click', this.onClick)
    this.trigger.addEventListener('keydown', this.onTriggerKey)
    // Capture on the window runs before the dialog's own Escape listener.
    window.addEventListener('keydown', this.onEscape, true)
  },
  first() {
    return this.menu.querySelector('[data-chip-focus]:not(:disabled), input:checked:not(:disabled), input:not(:disabled):not([type=hidden]), select:not(:disabled), button:not(:disabled)')
  },
  close() {
    if (!this.open) return
    this.open = false
    this.menu.hidePopover()
    this.trigger.focus()
  },
  destroyed() {
    window.removeEventListener('keydown', this.onEscape, true)
  },
}

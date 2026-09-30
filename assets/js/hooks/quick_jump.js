// Cmd/Ctrl-K uses the visible dialog trigger, as Cmd/Ctrl-N does New track's,
// preserving the shared dialog's push/pop focus stack. Arrow keys move through native navigation links, in
// search and in any `data-jump-scope` list; Enter in its query takes the first.
export const QuickJump = {
  mounted() {
    const mac = /Mac|iPhone|iPad|iPod/.test(navigator.userAgentData?.platform || navigator.platform)
    this.onKey = event => {
      const modifier = mac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey
      if (modifier && !event.altKey && event.key.toLowerCase() === 'k') {
        if (event.target.closest?.('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], .xterm')) return
        if (this.el.querySelector('[role="dialog"]')) return
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
    window.addEventListener('keydown', this.onKey)
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
  destroyed() { window.removeEventListener('keydown', this.onKey) },
}

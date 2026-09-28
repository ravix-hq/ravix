// Cmd/Ctrl-K uses the visible dialog trigger, preserving the shared dialog's
// push/pop focus stack. Arrow keys move through native navigation links.
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
      const dialog = this.el.querySelector('#search-dialog')
      if (!dialog || !dialog.contains(event.target)) return
      const results = [...dialog.querySelectorAll('[data-jump-result]')]
      if (!results.length) return
      const index = results.indexOf(document.activeElement)
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault()
        const next = index < 0 ? (event.key === 'ArrowDown' ? 0 : results.length - 1)
          : (index + (event.key === 'ArrowDown' ? 1 : -1) + results.length) % results.length
        results[next].focus()
      } else if (event.key === 'Enter' && event.target.id === 'search-query') {
        event.preventDefault()
        results[0].click()
      }
    }
    window.addEventListener('keydown', this.onKey)
  },
  destroyed() { window.removeEventListener('keydown', this.onKey) },
}

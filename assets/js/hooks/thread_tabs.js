// Manual-activation tabs: arrow keys move the one tab stop; Enter/Space
// selects through LiveView. Background activity must not reset overflow scroll.
export const ThreadTabs = {
  mounted() {
    this.focusTab = tab => {
      this.el.querySelectorAll('.thread-tab').forEach(item => { item.tabIndex = item === tab ? 0 : -1 })
    }
    this.focusin = event => {
      if (event.target.matches('.thread-tab')) this.focusTab(event.target)
    }
    this.keydown = event => {
      const tabs = [...this.el.querySelectorAll('.thread-tab')]
      const index = tabs.indexOf(event.target)
      if (index < 0 || event.altKey || event.ctrlKey || event.metaKey) return
      const next = new Map([['ArrowRight', (index + 1) % tabs.length],
        ['ArrowLeft', (index + tabs.length - 1) % tabs.length],
        ['Home', 0], ['End', tabs.length - 1]]).get(event.key)
      if (next === undefined) return
      event.preventDefault()
      tabs[next].focus()
      tabs[next].scrollIntoView({block: 'nearest', inline: 'nearest'})
    }
    this.el.addEventListener('keydown', this.keydown)
    this.el.addEventListener('focusin', this.focusin)
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
  },
  destroyed() {
    this.el.removeEventListener('keydown', this.keydown)
    this.el.removeEventListener('focusin', this.focusin)
  },
}

// Threads need local arrow-key focus and scroll visibility without waiting for
// a server patch. Selection still belongs to LiveView (Enter/Space or picker).
export const ThreadTabs = {
  mounted() {
    this.keydown = event => {
      const tabs = [...this.el.querySelectorAll('.thread-tab')]
      const index = tabs.indexOf(event.target)
      if (index < 0 || event.altKey || event.ctrlKey || event.metaKey) return
      const next = {ArrowRight: (index + 1) % tabs.length,
        ArrowLeft: (index + tabs.length - 1) % tabs.length,
        Home: 0, End: tabs.length - 1}[event.key]
      if (next === undefined) return
      event.preventDefault()
      tabs[next].focus()
      tabs[next].scrollIntoView({block: 'nearest', inline: 'nearest'})
    }
    this.el.addEventListener('keydown', this.keydown)
    this.updated()
  },
  updated() {
    this.el.querySelector('.thread-tab[aria-current="true"]')?.scrollIntoView({block: 'nearest', inline: 'nearest'})
  },
  destroyed() { this.el.removeEventListener('keydown', this.keydown) },
}

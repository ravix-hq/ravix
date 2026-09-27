// Manual activation keeps arrow-key exploration from mounting another track.
// Native vertical scrolling handles wheels, touch, and focused tabs.
export const TrackTabs = {
  mounted() {
    this.strip = this.el.querySelector('[role="tablist"]')
    this.rove = tab => {
      for (const item of this.strip.querySelectorAll('[role="tab"]')) {
        item.tabIndex = item === tab ? 0 : -1
      }
    }
    this.focus = event => {
      const tab = event.target.closest('[role="tab"]')
      if (tab) this.rove(tab)
    }
    this.keydown = event => {
      const tabs = [...this.strip.querySelectorAll('[role="tab"]')]
      const index = tabs.indexOf(event.target)
      if (index < 0 || event.altKey || event.ctrlKey || event.metaKey) return
      let next
      switch (event.key) {
        case 'ArrowDown': next = (index + 1) % tabs.length; break
        case 'ArrowUp': next = (index + tabs.length - 1) % tabs.length; break
        case 'Home': next = 0; break
        case 'End': next = tabs.length - 1; break
        case ' ': event.preventDefault(); event.target.click(); return
        default: return
      }
      event.preventDefault()
      tabs[next].focus()
    }
    this.strip.addEventListener('focusin', this.focus)
    this.strip.addEventListener('keydown', this.keydown)
    this.updated()
  },
  updated() {
    const selected = this.strip.querySelector('[aria-selected="true"]')
    const href = selected?.getAttribute('href')
    if (href !== this.selectedHref) {
      selected?.scrollIntoView({block: 'nearest', inline: 'nearest'})
      this.selectedHref = href
    }
    // LiveView patches may restore the server's tabindex during exploration.
    const focused = this.strip.contains(document.activeElement) && document.activeElement.closest('[role="tab"]')
    this.rove(focused || selected)
  },
  destroyed() {
    this.strip.removeEventListener('focusin', this.focus)
    this.strip.removeEventListener('keydown', this.keydown)
  },
}

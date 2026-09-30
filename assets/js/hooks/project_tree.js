// Collapse is a browser preference scoped to the signed-in viewer. LiveView
// patches may add projects, but must not undo a person's expanded/collapsed rows.
//
// The open track is kept in view (RAV-96): when it changes, or on the first
// paint, its project is opened if this viewer had folded it, and the rail
// scrolls just far enough to show its row. Anything else is left where the
// person put it, so a patch that only redraws a dot never moves the rail.
export const ProjectTree = {
  mounted() {
    this.key = `ravix.project-tree.${this.el.dataset.viewer}`
    this.collapsed = {}
    this.shown = null
    this.menus = new Set()
    try {
      const saved = JSON.parse(localStorage.getItem(this.key) || '{}')
      if (saved && typeof saved === 'object' && !Array.isArray(saved)) this.collapsed = saved
    } catch { /* Storage may be unavailable or contain an older value. */ }
    this.onClick = event => {
      const button = event.target.closest('[data-collapse]')
      if (!button || !this.el.contains(button)) return
      this.collapsed[button.dataset.collapse] = button.getAttribute('aria-expanded') === 'true'
      this.save()
      this.updated()
    }
    // A project's ⋯ menu is a menu button (RAV-96): its trigger says whether
    // it is open, opening it puts focus on the first item, the arrow keys,
    // Home and End move between items, and closing it returns focus to the
    // trigger. The native popover already brings Escape and light dismiss.
    // `toggle` does not bubble, so it is caught on the way down.
    this.onToggle = event => {
      const menu = event.target
      if (!menu.matches?.('.project-menu')) return
      const open = event.newState === 'open'
      if (open) this.menus.add(menu.id)
      else this.menus.delete(menu.id)
      this.trigger(menu)?.setAttribute('aria-expanded', String(open))
      if (open) this.items(menu)[0]?.focus()
      else if (!document.activeElement || document.activeElement === document.body || menu.contains(document.activeElement)) this.trigger(menu)?.focus()
    }
    this.onKey = event => {
      const menu = event.target.closest?.('.project-menu')
      if (menu) return this.move(menu, event)
      const trigger = event.target.closest?.('[aria-haspopup="menu"][popovertarget]')
      if (!trigger || !['ArrowDown', 'ArrowUp'].includes(event.key)) return
      const target = document.getElementById(trigger.getAttribute('popovertarget'))
      if (!target || this.menus.has(target.id)) return
      event.preventDefault()
      target.showPopover()
    }
    this.el.addEventListener('click', this.onClick)
    this.el.addEventListener('toggle', this.onToggle, true)
    this.el.addEventListener('keydown', this.onKey)
    this.updated()
  },
  trigger(menu) { return this.el.querySelector(`[popovertarget="${menu.id}"][aria-haspopup]`) },
  items(menu) { return [...menu.querySelectorAll('[role^="menuitem"]:not(:disabled)')] },
  move(menu, event) {
    const items = this.items(menu)
    const at = items.indexOf(document.activeElement)
    const next = {ArrowDown: at + 1, ArrowUp: at - 1, Home: 0, End: items.length - 1}[event.key]
    if (next === undefined || items.length === 0) return
    event.preventDefault()
    items[(next + items.length) % items.length].focus()
  },
  updated() {
    // A patch redraws the trigger as the server wrote it, closed.
    this.el.querySelectorAll('.project-menu').forEach(menu => {
      this.trigger(menu)?.setAttribute('aria-expanded', String(this.menus.has(menu.id)))
    })
    const open = this.el.querySelector('.track-tab[aria-current="page"]')
    const reveal = open && open.id !== this.shown
    this.shown = open ? open.id : null
    if (reveal) this.unfold(open)
    this.el.querySelectorAll('[data-collapse]').forEach(button => {
      const panel = document.getElementById(button.getAttribute('aria-controls'))
      if (!panel) return
      const collapsed = this.collapsed[button.dataset.collapse] ?? (button.getAttribute('aria-expanded') === 'false')
      button.setAttribute('aria-expanded', String(!collapsed))
      panel.hidden = collapsed
    })
    if (reveal) this.scrollTo(open)
  },
  // Open the folds this browser holds between the rail and the open track.
  // A named section's fold is the server's, and a track in it is left folded.
  unfold(row) {
    let changed = false
    for (let panel = row.parentElement; panel && panel !== this.el; panel = panel.parentElement) {
      const button = panel.id && this.el.querySelector(`[data-collapse][aria-controls="${panel.id}"]`)
      if (button && this.collapsed[button.dataset.collapse]) {
        this.collapsed[button.dataset.collapse] = false
        changed = true
      }
    }
    if (changed) this.save()
  },
  scrollTo(row) {
    const scroller = row.closest('.yard-scroll')
    if (!scroller || row.closest('[hidden]')) return
    const view = scroller.getBoundingClientRect(), box = row.getBoundingClientRect()
    // A closed drawer draws nothing to measure.
    if (view.height === 0) return
    const margin = 8
    if (box.top < view.top + margin) scroller.scrollTop -= view.top + margin - box.top
    else if (box.bottom > view.bottom - margin) scroller.scrollTop += box.bottom - (view.bottom - margin)
  },
  save() {
    try { localStorage.setItem(this.key, JSON.stringify(this.collapsed)) } catch { /* Optional preference. */ }
  },
  destroyed() {
    this.el.removeEventListener('click', this.onClick)
    this.el.removeEventListener('toggle', this.onToggle, true)
    this.el.removeEventListener('keydown', this.onKey)
  },
}

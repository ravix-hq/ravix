// Collapse is a browser preference scoped to the signed-in viewer. LiveView
// patches may add projects, but must not undo a person's expanded/collapsed rows.
export const ProjectTree = {
  mounted() {
    this.key = `ravix.project-tree.${this.el.dataset.viewer}`
    this.collapsed = {}
    try {
      const saved = JSON.parse(localStorage.getItem(this.key) || '{}')
      if (saved && typeof saved === 'object' && !Array.isArray(saved)) this.collapsed = saved
    } catch { /* Storage may be unavailable or contain an older value. */ }
    this.onClick = event => {
      const button = event.target.closest('[data-collapse]')
      if (!button || !this.el.contains(button)) return
      this.collapsed[button.dataset.collapse] = button.getAttribute('aria-expanded') === 'true'
      try { localStorage.setItem(this.key, JSON.stringify(this.collapsed)) } catch { /* Optional preference. */ }
      this.updated()
    }
    this.el.addEventListener('click', this.onClick)
    this.updated()
  },
  updated() {
    this.el.querySelectorAll('[data-collapse]').forEach(button => {
      const panel = document.getElementById(button.getAttribute('aria-controls'))
      if (!panel) return
      const collapsed = this.collapsed[button.dataset.collapse] ?? (button.getAttribute('aria-expanded') === 'false')
      button.setAttribute('aria-expanded', String(!collapsed))
      panel.hidden = collapsed
    })
  },
  destroyed() { this.el.removeEventListener('click', this.onClick) },
}

// Match settings' inline confirmation: focus the action, prevent leaving
// before a decision, and return focus to the removal button on cancellation.
// A compact card's Remove is in its ⋯ menu (RAV-77), which has closed by
// then; focus goes to the button that opens that menu instead.
export const AgentConfirmation = {
  mounted() {
    this.onClick = event => {
      const confirmation = this.el.querySelector('#agent-disconnect-confirmation')
      if (!confirmation && event.target.closest('[id^="remove-"]')) this.trigger = event.target.id
      if (!confirmation || confirmation.contains(event.target)) return
      event.preventDefault()
      event.stopImmediatePropagation()
      this.el.querySelector('#confirm-agent-disconnect')?.focus()
    }
    this.onKey = event => {
      if (event.key !== 'Escape' || !this.el.querySelector('#agent-disconnect-confirmation')) return
      event.preventDefault()
      event.stopImmediatePropagation()
      this.el.querySelector('#confirm-agent-disconnect')?.focus()
    }
    document.addEventListener('click', this.onClick, true)
    window.addEventListener('keydown', this.onKey, true)
  },
  updated() {
    const confirming = !!this.el.querySelector('#agent-disconnect-confirmation')
    if (this.confirming && !confirming) this.restore()
    this.confirming = confirming
  },
  restore() {
    const trigger = document.getElementById(this.trigger)
    const menu = trigger?.closest('[popover]')
    if (menu && !menu.matches(':popover-open')) document.querySelector(`[popovertarget="${menu.id}"]`)?.focus()
    else trigger?.focus()
  },
  destroyed() {
    document.removeEventListener('click', this.onClick, true)
    window.removeEventListener('keydown', this.onKey, true)
  }
}


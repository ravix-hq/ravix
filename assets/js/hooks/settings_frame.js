// A settings page opens each section at its top, as a page would: the
// frame scrolls itself, so LiveView's own scroll on a patch never reaches it.
// A URL naming a part of the page (`/settings/machine#machine-secrets`,
// where an old section's URL lands) opens at that part instead.
export const SettingsFrame = {
  mounted() {
    this.section = this.el.dataset.section
    this.reveal()
    this.revealErrors()
    this.onInvalid = event => openDetails(event.target)
    this.onHash = () => this.reveal()
    this.el.addEventListener('invalid', this.onInvalid, true)
    window.addEventListener('hashchange', this.onHash)
  },
  updated() {
    this.revealErrors()
    if (this.el.dataset.section === this.section) return
    this.section = this.el.dataset.section
    this.reveal()
  },
  reveal() {
    const id = decodeURIComponent(window.location.hash.slice(1))
    const part = id && document.getElementById(id)
    if (part && this.el.contains(part)) {
      openDetails(part)
      part.scrollIntoView({block: 'start'})
    }
    else this.el.scrollTop = 0
  },
  revealErrors() {
    for (const error of this.el.querySelectorAll('.error')) openDetails(error)
  },
  destroyed() {
    this.el.removeEventListener('invalid', this.onInvalid, true)
    window.removeEventListener('hashchange', this.onHash)
  },
}

function openDetails(element) {
  for (let details = element.closest('details'); details; details = details.parentElement?.closest('details')) {
    details.open = true
  }
}

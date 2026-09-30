// A settings page opens each section at its top, as a page would: the
// frame scrolls itself, so LiveView's own scroll on a patch never reaches it.
// A URL naming a part of the page (`/settings/machine#machine-secrets`,
// where an old section's URL lands) opens at that part instead.
export const SettingsFrame = {
  mounted() {
    this.section = this.el.dataset.section
    this.reveal()
  },
  updated() {
    if (this.el.dataset.section === this.section) return
    this.section = this.el.dataset.section
    this.reveal()
  },
  reveal() {
    const id = decodeURIComponent(window.location.hash.slice(1))
    const part = id && document.getElementById(id)
    if (part && this.el.contains(part)) part.scrollIntoView({block: 'start'})
    else this.el.scrollTop = 0
  },
}

// A settings page opens each section at its top, as a page would: the
// frame scrolls itself, so LiveView's own scroll on a patch never reaches it.
export const SettingsFrame = {
  mounted() {
    this.section = this.el.dataset.section
  },
  updated() {
    if (this.el.dataset.section === this.section) return
    this.section = this.el.dataset.section
    this.el.scrollTop = 0
  },
}

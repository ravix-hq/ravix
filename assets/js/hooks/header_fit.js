// A track header's status chips show their words whole or not at all
// (RAV-63). The CSS already makes them give way before the title, but flex
// shrinks continuously, so a chip squeezed part-way reads "• S" or "Own m".
// A label that is cut short puts the header in `data-compact`, where every
// status chip drops to its dot, icon or count; it leaves again only once the
// spacer has room for all of them, so the two states cannot chase each
// other. A header whose contents run past its end (the share button, its
// viewer count, the close button) is compact too, whatever its labels say. Layout is the browser's
// to measure, which is why this is a hook and not a template.

// The grid gap a label brings back with it (`.track-header-status .chip`).
export const LABEL_GAP = 5

const cut = el => el.scrollWidth > el.clientWidth + 1

export function compact(header) {
  const labels = [...header.querySelectorAll("[data-fit-label]")]
  if (labels.length === 0) return false
  if (cut(header)) return true
  if (!header.hasAttribute("data-compact")) return labels.some(cut)
  const spare = header.querySelector(".spacer")?.clientWidth ?? 0
  const needed = labels.reduce((sum, el) => sum + el.scrollWidth + LABEL_GAP, 0)
  return spare < needed
}

export const HeaderFit = {
  mounted() {
    this.observer = new ResizeObserver(() => this.fit())
    this.observer.observe(this.el)
    const spacer = this.el.querySelector(".spacer")
    if (spacer) this.observer.observe(spacer)
    this.fit()
  },
  // A patch that lands a chip or strips the attribute is measured again.
  updated() {
    this.fit()
  },
  destroyed() {
    this.observer?.disconnect()
  },
  fit() {
    this.el.toggleAttribute("data-compact", compact(this.el))
  },
}

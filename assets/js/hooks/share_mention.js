// The Share dialog's @-mention box (ADR 0009 phase 5): a combobox over the
// listbox of workspace members the server renders as you type. The server
// decides who is offered and refuses anybody else; this only moves the
// highlight, as the ARIA combobox pattern asks: ArrowDown/ArrowUp move it,
// Enter adds the highlighted person, Escape closes the list without closing
// the dialog. The first match is highlighted as the list arrives, so Enter
// after typing adds the person you meant.
export const ShareMention = {
  mounted() {
    this.input = this.el.querySelector("[role=combobox]")
    this.onKey = e => this.key(e)
    this.input.addEventListener("keydown", this.onKey)
    this.highlight(this.options()[0] ?? null)
  },

  updated() {
    // A patch redraws the options with `aria-selected="false"` and drops
    // the attribute this hook set on the input; keep the same person
    // highlighted if they are still offered, else the first.
    const login = this.active?.dataset.login
    const options = this.options()
    this.highlight(options.find(o => o.dataset.login === login) ?? options[0] ?? null)
  },

  destroyed() {
    this.input?.removeEventListener("keydown", this.onKey)
  },

  listbox() {
    return document.getElementById(this.input.getAttribute("aria-controls"))
  },

  /** The options on show: none while the list is hidden. */
  options() {
    const list = this.listbox()
    if (!list || list.hidden) return []
    return Array.from(list.querySelectorAll("[role=option]"))
  },

  key(e) {
    if (e.isComposing) return
    const options = this.options()
    if (options.length === 0) return
    const at = options.indexOf(this.active)

    if (e.key === "ArrowDown") this.highlight(options[(at + 1) % options.length])
    else if (e.key === "ArrowUp") this.highlight(options[(at - 1 + options.length) % options.length])
    else if (e.key === "Enter" && this.active) this.pushEventTo(this.el, "add", {login: this.active.dataset.login})
    else if (e.key === "Escape") this.close()
    else return

    e.preventDefault()
    // Escape here closes the list, not the dialog around it.
    e.stopPropagation()
  },

  highlight(option) {
    for (const o of this.options()) o.setAttribute("aria-selected", String(o === option))
    this.active = option
    if (option) {
      this.input.setAttribute("aria-activedescendant", option.id)
      option.scrollIntoView?.({block: "nearest"})
    } else {
      this.input.removeAttribute("aria-activedescendant")
    }
  },

  close() {
    const list = this.listbox()
    if (list) list.hidden = true
    this.input.setAttribute("aria-expanded", "false")
    this.highlight(null)
  },
}

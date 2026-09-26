// JS.focus repeats focus on a later animation frame, which can steal typing
// after a person picks another field. Dialog content is already visible when
// mounted: focus once synchronously and leave any chosen field alone.
export const ProjectFormFocus = {
  mounted() {
    if (!this.el.contains(document.activeElement)) {
      this.el.querySelector(this.el.dataset.focus)?.focus()
    }
  },
}

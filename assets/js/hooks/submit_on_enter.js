// A textarea whose Enter submits its form, as the composer's does; Shift+Enter
// is a new line and an IME composition keeps its Enter. The form's own submit
// button decides: while it is disabled (refs still loading, a create already
// under way) Enter does nothing, so a key cannot do what a click could not.
// That button may sit outside the form, in a dialog's footer, and belong to
// it by `form=`, so it is looked for among the form's elements.
export const SubmitOnEnter = {
  mounted() {
    this.el.addEventListener("keydown", e => {
      if (e.key !== "Enter" || e.shiftKey || e.isComposing) return
      e.preventDefault()
      const form = this.el.form
      const button = form && [...form.elements].find(el => el.tagName === "BUTTON" && el.type === "submit")
      if (!form || button?.disabled) return
      form.requestSubmit(button ?? undefined)
    })
  },
}

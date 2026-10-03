// The Project sections dialog's New section form (RAV-130). When the server
// says the section was created, the field is emptied and focused, ready for
// the next name. The server cannot do this alone: it rendered `value=""`
// before the submit and renders `value=""` after it, so the patch has
// nothing to change and the typed name would stay, looking as if the click
// had done nothing. A reset here before the server answered would also
// clear a name it was about to refuse, which is why it waits for the event.
//
// The focus waits a frame: LiveView blurs whatever was active when a form
// is submitted and gives it the focus back right after the reply's patch
// and events, which after a click on Create section is the button. One
// frame later that has happened, and the field is where the next name goes.
export const SectionForm = {
  mounted() {
    this.handleEvent("section-created", () => {
      this.el.reset()
      requestAnimationFrame(() => this.el.querySelector("input[name='section[name]']")?.focus())
    })
  },
}

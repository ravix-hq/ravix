// The token or key field of the agent panel (`RavixWeb.Live.AgentPanel`).
//
// The server never holds what is pasted here: the value is not an assign, so
// the field is rendered with none, and every patch of the panel (the button
// going busy, a Fountain read landing) would reset it to that nothing. The
// input is `phx-update="ignore"` so the browser's copy survives, and this
// hook applies what the server does say about the field, from its data
// attributes, since an ignored element takes nothing else:
//
//   data-state     "idle", "connecting" or "refused"
//   data-disabled  whether the panel is busy
//   data-invalid   whether a refusal is shown beside it
//
// The paste stays through "connecting" and through "refused", so a failure
// does not mean pasting it again (RAV-135). It is cleared on the change back
// to "idle": the attempt succeeded, or the form was reset for another agent
// or another way to pay.
export const CredentialField = {
  mounted() {
    this.state = this.el.dataset.state
    this.apply()
  },
  updated() {
    const was = this.state
    this.state = this.el.dataset.state
    if (this.state === "idle" && was !== "idle") this.el.value = ""
    this.apply()
  },
  apply() {
    this.el.disabled = this.el.dataset.disabled === "true"
    if (this.el.dataset.invalid === "true") this.el.setAttribute("aria-invalid", "true")
    else this.el.removeAttribute("aria-invalid")
  },
}

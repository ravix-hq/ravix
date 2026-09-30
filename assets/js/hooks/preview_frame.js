// The Preview tab's path bar. The preview is a frame on another origin, so
// the page can neither read where it is nor drive its history, and a
// navigation the page started itself would reach the gateway cross-site and
// be refused. The gateway's bridge inside the frame does both instead: it
// posts where it is to this origin, and takes back, forward, reload and "go"
// from this page. This hook is the other end, and it only talks to the
// frame's own origin (`data-origin`) and only listens to that frame.
//
// What the frame reports is shown, never trusted: the only thing sent to
// the server is whether the frame is up or unreachable, which draws the
// empty state and nothing else.
export const PreviewFrame = {
  mounted() {
    this.state = null
    this.onMessage = (event) => this.receive(event)
    this.onClick = (event) => {
      const button = event.target.closest("[data-preview-nav]")
      if (!button || button.disabled || !this.el.contains(button)) return
      this.send({type: button.dataset.previewNav})
    }
    this.onSubmit = (event) => {
      if (!event.target.matches("[data-preview-go]")) return
      event.preventDefault()
      const input = this.input()
      const path = this.normalize(input?.value)
      if (path) this.send({type: "go", path})
      // As an address bar does: let go, so the frame's answer shows in it.
      input?.blur()
    }
    window.addEventListener("message", this.onMessage)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("submit", this.onSubmit)
    this.origin = this.el.dataset.origin || null
  },
  updated() {
    // A new port or a fresh ticket is a new page: start the bar from the top.
    const origin = this.el.dataset.origin || null
    if (origin !== this.origin) {
      this.origin = origin
      this.state = null
      const input = this.input()
      if (input) input.value = "/"
    }
  },
  destroyed() {
    window.removeEventListener("message", this.onMessage)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("submit", this.onSubmit)
  },
  frame() {
    return this.el.querySelector("iframe")
  },
  input() {
    return this.el.querySelector("#preview-location")
  },
  receive(event) {
    const frame = this.frame()
    const data = event.data
    if (!this.origin || event.origin !== this.origin) return
    if (!frame || event.source !== frame.contentWindow) return
    if (!data || data.source !== "ravix-preview" || data.type !== "location") return

    const input = this.input()
    if (input && document.activeElement !== input && typeof data.path === "string") {
      input.value = data.path
    }

    const state = data.state === "unreachable" ? "unreachable" : "ok"
    if (state === this.state) return
    this.state = state
    const port = Number.isInteger(data.port) ? data.port : null
    this.pushEvent("preview-frame", state === "unreachable" ? {state, port} : {state})
  },
  send(message) {
    const frame = this.frame()
    if (!frame?.contentWindow || !this.origin) return
    frame.contentWindow.postMessage({source: "ravix", ...message}, this.origin)
  },
  // A path on the frame's own origin, whatever was typed: "about" is
  // "/about", and anything naming another origin is dropped here as well as
  // by the bridge.
  normalize(value) {
    const text = (value || "").trim()
    if (text === "") return "/"
    try {
      const url = new URL(text.startsWith("/") ? text : `/${text}`, this.origin)
      return url.origin === this.origin ? url.pathname + url.search + url.hash : null
    } catch {
      return null
    }
  },
}

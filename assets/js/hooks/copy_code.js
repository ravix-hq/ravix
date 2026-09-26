// Help examples are copied in the browser: a server event cannot access the
// clipboard. Read the rendered code so escaping and multiline JSON stay exact.
export const CopyCode = {
  mounted() {
    this.button = this.el.querySelector("button")
    this.status = this.el.querySelector('[role="status"]')
    this.copy = async () => {
      if (this.button.disabled) return
      this.button.disabled = true
      this.status.textContent = "Copying…"
      let message
      try {
        await navigator.clipboard.writeText(this.el.querySelector("code").textContent)
        message = "Copied"
      } catch {
        message = "Copy failed. Select and copy the code."
      }
      if (!this.removed) {
        this.status.textContent = message
        this.button.disabled = false
      }
    }
    this.button.addEventListener("click", this.copy)
  },
  destroyed() {
    this.removed = true
    this.button.removeEventListener("click", this.copy)
  },
}

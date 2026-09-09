// The terminal, which is a shell and says so.
//
// The server gives this panel exactly one thing: a command in, a result out,
// on the machine the track's worktree lives on. That is less than a terminal
// emulator, so there is no tty and `vim` opens nothing, and more than a chat
// message, because these commands skip the box's one-turn-at-a-time lock and
// `git status` answers while the agent is mid-edit. Keystrokes never
// round-trip: the line is edited here, history is kept here, and only a
// finished command goes to the server. What the hook expects, on the panel:
//
//   <div phx-hook="Terminal" id="terminal" class="term">
//     <div class="term-scroll" data-terminal-output>… the blocks …</div>
//     <div class="term-input">
//       <span class="ps1">{@cwd_base} $</span>
//       <input data-terminal-input aria-label="Command" disabled={@busy} />
//       <button type="button" class="ghost" phx-click="clear">Clear</button>
//     </div>
//   </div>
//
// Events pushed to the LiveView:
//
//   "exec"   %{"command" => "git status"}   on Enter, with a non-empty line
//   "clear"  %{}                             on Ctrl+L or Cmd+L
//
// The output follows itself: after every patch the scroller goes to the
// bottom, unless the reader has scrolled up to read back through a long
// build's output, in which case being yanked to the bottom by its last line
// is the specific annoyance this exists to prevent.

const HISTORY = 200
/** Within this many pixels of the bottom still counts as following. */
const SLACK = 24

export const Terminal = {
  mounted() {
    // Oldest first, with `cursor` counting back from the end. Null means
    // "typing something new", which is what distinguishes pressing down past
    // the newest entry from having never pressed up at all.
    this.history = []
    this.cursor = null
    this.following = true

    const output = this.output()
    output?.addEventListener("scroll", () => {
      this.following = output.scrollHeight - output.scrollTop - output.clientHeight < SLACK
    })
    output?.addEventListener("click", () => this.input()?.focus())

    this.el.addEventListener("keydown", e => {
      const input = this.input()
      if (!input || e.target !== input) return
      if (e.key === "Enter") {
        const command = input.value.trim()
        if (command && !input.disabled) this.run(command)
        return
      }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "l") {
        e.preventDefault()
        this.pushEvent("clear", {})
        return
      }
      if (e.key === "ArrowUp" || e.key === "ArrowDown") {
        if (!this.history.length) return
        e.preventDefault()
        const next = e.key === "ArrowUp" ? Math.min((this.cursor ?? -1) + 1, this.history.length - 1) : (this.cursor ?? -1) - 1
        if (next < 0) {
          this.cursor = null
          input.value = ""
          return
        }
        this.cursor = next
        input.value = this.history[this.history.length - 1 - next] ?? ""
      }
    })
    this.el.addEventListener("input", e => {
      if (e.target === this.input()) this.cursor = null
    })
    this.stick()
  },

  updated() {
    this.stick()
    // The input comes back enabled when the command has answered; the next
    // one should not need a click first.
    const input = this.input()
    if (input && !input.disabled && this.wasBusy) input.focus()
    this.wasBusy = Boolean(input?.disabled)
  },

  output() {
    return this.el.querySelector("[data-terminal-output]")
  },

  input() {
    return this.el.querySelector("[data-terminal-input]")
  },

  run(command) {
    this.history = [...this.history.filter(c => c !== command), command].slice(-HISTORY)
    this.cursor = null
    const input = this.input()
    if (input) input.value = ""
    this.following = true
    this.wasBusy = true
    this.pushEvent("exec", {command})
  },

  stick() {
    const output = this.output()
    if (output && this.following) output.scrollTop = output.scrollHeight
  },
}

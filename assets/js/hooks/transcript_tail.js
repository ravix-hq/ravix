// The scrollback's tail.
//
// Follow the bottom, but only while the reader is already there. Yanking
// somebody back down mid-scroll is the single most irritating thing a live
// transcript can do, and it happens on every chunk; so the position is read
// from the scroll rather than from a click, and a reader who has gone up to
// read gets a "jump to latest" affordance instead of a shove. What the hook
// expects, on the scroll container:
//
//   <div phx-hook="TranscriptTail" id="transcript-scroll" class="transcript-scroll"
//        data-track={@thread_id} data-older-event="older">
//     <div>… anything above the turns …</div>
//     <div id="transcript-turns" phx-update="stream">… the turns …</div>
//     <button type="button" class="jump-latest" data-jump-latest>Jump to latest</button>
//   </div>
//
//   The button sits after the turns, as a child of the scroller rather than
//   of the stream container (a stream owns its children). The stylesheet
//   shows it only under `.transcript-scroll.unpinned` (or `.scroll.unpinned`),
//   which is the class this hook toggles.
//
//   data-track        holds the selected thread id; changing it re-pins
//                     the panel to the bottom whatever they had scrolled to
//   data-older-event  optional; pushed to the LiveView when the reader nears
//                     the top, so a page of older turns can be laid in above.
//                     The hook anchors the first visible turn across patches,
//                     so prepending history and appending live output together
//                     leave what the reader is looking at in place.
//
// The hook toggles `unpinned` on the container while the reader is away from
// the bottom, which is what shows the affordance; clicking it pins again.
//
// It also owns the copy button on every fenced code block the markdown
// renderer emits (`button.code-copy` inside `.code-block`): the block's text,
// verbatim, to the clipboard, with the button saying what happened. The same
// goes for a turn footer's copy icon (`data-copy`) and its ⋯ menu's two
// items, "Copy link to turn" (`data-copy-link`, a path made absolute here)
// and "Copy text" (`data-copy-text`); the menu closes as they go, so its
// trigger says what happened instead (RAV-93).
//
// And the rest of RAV-93's reading surface:
//
//   `scrolled` is on the container while it is scrolled off its top, which
//   is what fades the text out under the tab strip.
//
//   A printable key pressed while the transcript has focus, as it does after
//   a click into it, is typed into the composer rather than going nowhere.
//   Space still scrolls, and a field in the transcript keeps its own keys.
//
//   A URL whose fragment names a turn (`#turns-<id>`, what "Copy link to
//   turn" copies) scrolls to that turn once it is drawn, and leaves the panel
//   unpinned there.

/** Within this many pixels of the bottom still counts as reading the bottom. */
const SLACK = 80
/** Scrolling to within this many pixels of the top asks for the page above. */
const REACH = 600

function hasSelection(element) {
  const selection = element.ownerDocument.getSelection()
  if (!selection || selection.isCollapsed) return false
  for (let i = 0; i < selection.rangeCount; i++) {
    if (selection.getRangeAt(i).intersectsNode(element)) return true
  }
  return false
}

export const TranscriptTail = {
  mounted() {
    this.pinned = true
    this.anchor = null
    this.track = this.el.dataset.track
    this.asked = false

    this.el.addEventListener("scroll", () => {
      // Both measurements are taken before the class is written. A style
      // write between two layout reads is what makes the browser lay the
      // page out again in the middle of the handler, and this handler runs
      // on every frame of a scroll through a transcript that can be a day's
      // work long.
      const top = this.el.scrollTop
      this.pinned = this.distance() < SLACK
      this.el.classList.toggle("unpinned", !this.pinned)
      this.el.classList.toggle("scrolled", top > 0)
      if (this.pinned) this.asked = false
      if (top < REACH) this.older()
    })
    this.el.addEventListener("click", e => {
      if (e.target.closest("[data-jump-latest]")) {
        this.pinned = true
        this.stick()
        this.el.classList.remove("unpinned")
        return
      }
      if (e.target.closest("#load-earlier")) {
        this.pinned = false
        this.el.classList.add("unpinned")
      }
      const button = e.target.closest("button.code-copy")
      if (button && this.el.contains(button)) this.copy(button)
      const answer = e.target.closest("button[data-copy]")
      if (answer && this.el.contains(answer)) this.copyAnswer(answer)
      const link = e.target.closest("button[data-copy-link]")
      if (link && this.el.contains(link)) {
        this.copyFromMenu(link, new URL(link.dataset.copyLink, window.location.href).href, "Link copied")
      }
      const text = e.target.closest("button[data-copy-text]")
      if (text && this.el.contains(text)) this.copyFromMenu(text, text.dataset.copyText, "Text copied")
    })
    this.el.addEventListener("keydown", e => this.forward(e))

    // Most of what makes this panel taller does not arrive with a patch: an
    // avatar decoding, a diff laying out, a font. Observing the content and
    // the scroller keeps the bottom through all of it.
    this.observer = new ResizeObserver(() => this.stick())
    this.observer.observe(this.el)
    this.observeContent()
    this.stick()
    this.reveal()
  },

  beforeUpdate() {
    // Prefer a visible turn; distance from the bottom is the fallback while
    // the transcript is empty. Pinned updates need no layout measurements.
    this.anchor = this.pinned ? null : this.el.scrollHeight - this.el.scrollTop
    this.turnAnchor = null
    if (this.pinned) return
    const top = this.el.getBoundingClientRect().top
    const turn = [...this.el.querySelectorAll("#transcript-turns > article")]
      .find(turn => turn.getBoundingClientRect().bottom > top)
    this.turnAnchor = turn
      ? { id: turn.id, top: turn.getBoundingClientRect().top }
      : null
  },

  updated() {
    if (this.el.dataset.track !== this.track) {
      // A new track starts pinned.
      this.track = this.el.dataset.track
      this.pinned = true
      this.asked = false
      this.el.classList.remove("unpinned")
    }
    if (this.pinned) {
      this.stick()
    } else if (this.anchor !== null) {
      const turn = this.turnAnchor && this.el.ownerDocument.getElementById(this.turnAnchor.id)
      if (turn) this.el.scrollTop += turn.getBoundingClientRect().top - this.turnAnchor.top
      else this.el.scrollTop = this.el.scrollHeight - this.anchor
      this.asked = false
    }
    this.anchor = null
    // A patch writes the scroller's class attribute back to what the server
    // rendered, so the two classes this hook put there are gone until the
    // next scroll event: `unpinned` is what shows Jump to latest, and the
    // first patch after the reader scrolled up -- the setup card folding,
    // a token landing -- took the pill away. Both are this hook's state and
    // are put back here.
    this.el.classList.toggle("unpinned", !this.pinned)
    this.el.classList.toggle("scrolled", this.el.scrollTop > 0)
    this.observeContent()
    this.reveal()
  },

  // Every element child, not just the first: the scroller's own box does not
  // resize when its content grows, so the growth has to be watched on what
  // actually grows. Watching only the first child broke silently the moment a
  // fixed-height ribbon was laid in above the turns; re-observing an element
  // already observed is a no-op, so this is safe to repeat after every patch.
  observeContent() {
    for (const child of this.el.children) this.observer.observe(child)
  },

  destroyed() {
    this.observer?.disconnect()
  },

  distance() {
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
  },

  stick() {
    if (this.pinned && !hasSelection(this.el)) this.el.scrollTop = this.el.scrollHeight
  },

  // Asked once per approach to the top; the patch that answers resets it.
  older() {
    const event = this.el.dataset.olderEvent
    if (!event || this.asked) return
    this.asked = true
    this.pushEvent(event, {})
  },

  // Scroll to the turn the URL's fragment names, once. The transcript loads
  // after mount, so this is tried on each patch until the turns are there;
  // a turn not among them (older history, another thread's) is given up on.
  reveal() {
    if (this.revealed) return
    const id = decodeURIComponent(window.location.hash.slice(1))
    const turns = this.el.querySelector("#transcript-turns")
    if (!id.startsWith("turns-")) {
      this.revealed = true
      return
    }
    if (!turns || turns.children.length === 0) return
    this.revealed = true
    const turn = this.el.ownerDocument.getElementById(id)
    if (!turn || turn.parentElement !== turns) return
    this.pinned = false
    this.el.classList.add("unpinned")
    turn.scrollIntoView({block: "start"})
  },

  // A printable key pressed on the transcript itself goes into the
  // composer, with the caret after it. Not Space, which scrolls; not a
  // chord; not a key meant for a field or menu inside the transcript.
  forward(e) {
    if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || e.isComposing) return
    if (e.key.length !== 1 || e.key === " ") return
    if (e.target.closest?.("input, textarea, select, [contenteditable], [popover]")) return
    const composer = this.el.ownerDocument.querySelector('#composer-form textarea[name="text"]')
    if (!composer || composer.disabled || composer.readOnly) return
    e.preventDefault()
    composer.focus()
    composer.setRangeText(e.key, composer.selectionStart, composer.selectionEnd, "end")
    composer.dispatchEvent(new Event("input", {bubbles: true}))
  },

  // A menu item closes its menu, so what happened is said on the menu's
  // trigger, the element focus returns to.
  async copyFromMenu(item, text, done) {
    if (item.disabled) return
    const trigger = item.closest(".chip-menu")?.querySelector("[popovertarget]")
    const label = trigger?.getAttribute("aria-label")
    try {
      await navigator.clipboard.writeText(text ?? "")
      trigger?.setAttribute("aria-label", done)
      trigger?.classList.add("copied")
    } catch {
      trigger?.setAttribute("aria-label", "Copy failed. Try again")
    } finally {
      window.setTimeout(() => {
        if (!trigger?.isConnected) return
        trigger.setAttribute("aria-label", label)
        trigger.classList.remove("copied")
      }, 2000)
    }
  },

  // A turn's answer, as the markdown it was written in. The button is an
  // icon, so what happened is said through its label and a class.
  async copyAnswer(button) {
    if (button.disabled) return
    button.disabled = true
    try {
      await navigator.clipboard.writeText(button.dataset.copy ?? "")
      button.setAttribute("aria-label", "Answer copied")
      button.classList.add("copied")
    } catch {
      button.setAttribute("aria-label", "Copy failed. Try again")
    } finally {
      button.disabled = false
      window.setTimeout(() => {
        if (!button.isConnected) return
        button.setAttribute("aria-label", "Copy answer")
        button.classList.remove("copied")
      }, 2000)
    }
  },

  async copy(button) {
    if (button.disabled) return
    const code = button.closest(".code-block")?.querySelector("pre code")
    if (!code) return
    button.disabled = true
    try {
      await navigator.clipboard.writeText(code.textContent ?? "")
      button.textContent = "Copied!"
      button.setAttribute("aria-label", "Code copied")
    } catch {
      button.textContent = "Copy failed"
      button.setAttribute("aria-label", "Copy failed. Try again")
    } finally {
      button.disabled = false
      window.setTimeout(() => {
        if (!button.isConnected) return
        button.textContent = "Copy"
        button.setAttribute("aria-label", "Copy code")
      }, 2000)
    }
  },
}

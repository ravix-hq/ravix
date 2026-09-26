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
//        data-track={@track.id} data-older-event="older">
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
//   data-track        changes when the reader is somewhere new, which re-pins
//                     the panel to the bottom whatever they had scrolled to
//   data-older-event  optional; pushed to the LiveView when the reader nears
//                     the top, so a page of older turns can be laid in above.
//                     The hook measures the distance from the bottom before
//                     each patch and restores it after, so what the reader is
//                     looking at does not move when the page above lands.
//
// The hook toggles `unpinned` on the container while the reader is away from
// the bottom, which is what shows the affordance; clicking it pins again.
//
// It also owns the copy button on every fenced code block the markdown
// renderer emits (`button.code-copy` inside `.code-block`): the block's text,
// verbatim, to the clipboard, with the button saying what happened.

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
      const button = e.target.closest("button.code-copy")
      if (button && this.el.contains(button)) this.copy(button)
      const answer = e.target.closest("button[data-copy]")
      if (answer && this.el.contains(answer)) this.copyAnswer(answer)
    })

    // Most of what makes this panel taller does not arrive with a patch: an
    // avatar decoding, a diff laying out, a font. Observing the content and
    // the scroller keeps the bottom through all of it.
    this.observer = new ResizeObserver(() => this.stick())
    this.observer.observe(this.el)
    this.observeContent()
    this.stick()
  },

  beforeUpdate() {
    // The distance from the bottom, so a page laid in above can be undone
    // from the reader's point of view after the patch.
    this.anchor = this.pinned ? null : this.el.scrollHeight - this.el.scrollTop
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
      this.el.scrollTop = this.el.scrollHeight - this.anchor
      this.asked = false
    }
    this.anchor = null
    this.observeContent()
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

// The prompt box.
//
// Enter sends and Shift+Enter is a newline: the other way round is correct
// for a document and wrong for a conversation. The box grows with what is
// in it up to a ceiling and then scrolls, because a textarea that grows
// without limit pushes the transcript off the screen at exactly the moment
// somebody is writing a long instruction and wants to see what they are
// instructing about. Pasted and dropped images become the same thing the
// attach button produces: files on the form's upload input, which is how
// `allow_upload` on the server sees them. What the hook expects:
//
//   <form phx-submit="send">
//     <div class="composer-box" data-composer-box>
//       <div class="composer-note" role="status" data-composer-note hidden></div>
//       <textarea phx-hook="Composer" id="composer" name="text" rows="1"
//                 data-draft-key={"track:" <> @track.id}
//                 data-typing-event="typing"></textarea>
//       <.live_file_input upload={@uploads.images} class="offscreen" />
//       …
//     </div>
//   </form>
//
//   data-draft-key     the box remembers what was typed, per track, so a
//                      click away and back does not lose a paragraph
//   data-typing-event  optional; pushed while there is something in the box,
//                      throttled here to the server's typing lease
//
// The upload input is found by walking up to the form (or `.composer-box`)
// and looking for `input[type=file]`. Files that Fountain would refuse are
// turned away before they are attached, with the reason written into
// `[data-composer-note]`, because a rejection that arrives as a failed turn
// is a rejection nobody can act on.
//
// In Comment mode (`data-mode="comment"`) the box is text only, and typing
// `@` opens the list of people who can be mentioned: the server renders
// them into the `role="listbox"` the textarea's `aria-controls` names, and
// this hook filters it by what follows the `@`, moves through it with the
// arrow keys, and puts `@login ` in the box on Enter, Tab or a click.
//
// Sending clears the remembered draft; the text itself stays until the
// server says the prompt was saved, by pushing `composer:clear` to this
// hook. A save that fails leaves the words where they were, which is the
// point: a composer that eats a paragraph on a network blip is unforgivable
// in a way a visible error is not.

const CEILING = 260
const DRAFT_PREFIX = "ravix.draft."
const TYPING_EVERY = 1500

/** The four Fountain takes, and so the four the picker offers. */
const ACCEPTED = ["image/png", "image/jpeg", "image/gif", "image/webp"]
const MAX_IMAGES = 6
const MAX_IMAGE_BYTES = 8 * 1024 * 1024

/** Sort what somebody just handed us into what can go and what cannot. */
export function accept(files, held) {
  const accepted = []
  const rejected = []
  for (const file of files) {
    const name = file.name || "that image"
    if (!ACCEPTED.includes(file.type)) rejected.push({name, why: "type"})
    else if (file.size > MAX_IMAGE_BYTES) rejected.push({name, why: "size"})
    else if (held + accepted.length >= MAX_IMAGES) rejected.push({name, why: "count"})
    else accepted.push(file)
  }
  return {accepted, rejected}
}

/** One line saying what was turned away and why. Null when nothing was. */
export function rejectionMessage(rejected) {
  if (!rejected.length) return null
  const of = why => rejected.filter(r => r.why === why).map(r => r.name)
  const parts = []
  const wrongType = of("type")
  const tooBig = of("size")
  const overflow = of("count")
  if (wrongType.length) parts.push(`${list(wrongType)}: only PNG, JPEG, GIF and WebP.`)
  if (tooBig.length) parts.push(`${list(tooBig)}: larger than 8 MB.`)
  if (overflow.length) parts.push(`${list(overflow)}: ${MAX_IMAGES} images at a time.`)
  return parts.join(" ")
}

/** The `@partial` being typed just before the caret, or null. */
export function mentionQuery(text, caret) {
  const match = /(^|[^\w@/`])@([A-Za-z0-9-]{0,39})$/.exec(text.slice(0, caret))
  return match ? {start: caret - match[2].length - 1, query: match[2]} : null
}

function list(names) {
  if (names.length <= 1) return names[0] ?? ""
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`
}

export const Composer = {
  mounted() {
    this.key = this.el.dataset.draftKey ? DRAFT_PREFIX + this.el.dataset.draftKey : null
    this.lastTyping = 0
    this.restore()
    this.grow()

    this.el.addEventListener("input", () => {
      this.grow()
      this.save()
      this.mention()
      if (this.el.value.trim()) this.typing()
    })
    this.el.addEventListener("keydown", e => {
      if (this.mentionKey(e)) {
        e.preventDefault()
      } else if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault()
        this.submit()
      } else if (e.key === "Escape") {
        this.forget()
      }
    })
    this.el.addEventListener("paste", e => {
      // Only when the clipboard actually carried files. Pasting text that
      // happens to come from an image editor must still paste.
      if (this.attach(e.clipboardData?.files)) e.preventDefault()
    })

    const box = this.box()
    this.onDragOver = e => {
      if (!e.dataTransfer?.types.includes("Files")) return
      // Without this the browser navigates to the dropped file, which
      // discards whatever was half-written in the box.
      e.preventDefault()
      box.classList.add("dragging")
    }
    this.onDragLeave = e => {
      if (box.contains(e.relatedTarget)) return
      box.classList.remove("dragging")
    }
    this.onDrop = e => {
      if (!e.dataTransfer?.types.includes("Files")) return
      e.preventDefault()
      box.classList.remove("dragging")
      this.attach(e.dataTransfer.files)
    }
    // Kept, rather than looked up again when the time comes to unbind. By
    // then this textarea has been taken out of the document -- moving
    // between tracks changes its id, so it is replaced rather than patched
    // -- and `box()` walks upwards from it, which from a detached element
    // finds nothing. Removing a listener from whatever a second lookup
    // happens to return would be wrong even where it found something.
    this.onMentionPick = e => {
      const option = e.target.closest?.("[data-mention-options] [role=option]")
      if (!option) return
      // Keep the caret in the box: the choice is made on the way down.
      e.preventDefault()
      this.choose(option)
    }
    this.boundBox = box
    box.addEventListener("mousedown", this.onMentionPick)
    box.addEventListener("dragover", this.onDragOver)
    box.addEventListener("dragleave", this.onDragLeave)
    box.addEventListener("drop", this.onDrop)

    this.boundForm = this.el.form
    this.onSubmit = () => this.save()
    this.boundForm?.addEventListener("submit", this.onSubmit)

    this.handleEvent("composer:insert", ({text}) => {
      this.el.value = text
      this.save()
      this.grow()
      this.el.focus()
    })
    this.handleEvent("composer:retry", ({text, images}) => {
      if (this.el.value.trim() || this.picker()?.files?.length ||
          this.box().querySelector(".workspace-upload, [phx-click='clear-attachments']")) {
        this.note("Your draft is still here. Send or clear it before retrying an earlier message.")
        this.el.focus()
        return
      }
      this.el.value = text
      this.save()
      this.grow()
      this.el.focus()
      this.note(images
        ? "Review your message and reattach its images, then send to retry."
        : "Review your message, then send to retry.")
    })
    // A draft thread's box is gone once the draft is sent or discarded, and
    // what it remembered goes with it; the key names that box, not this one.
    this.handleEvent("composer:forget", ({key}) => {
      try {
        localStorage.removeItem(DRAFT_PREFIX + key)
      } catch {
        // Nothing to forget.
      }
    })
    this.handleEvent("composer:clear", () => {
      this.el.value = ""
      this.forget()
      this.grow()
      this.note(null)
    })
  },

  updated() {
    this.restore()
    this.grow()
    // A patch rewrites the textarea's attributes from the template, which
    // does not know which option is highlighted.
    if (this.active && this.mentions()) this.el.setAttribute("aria-activedescendant", this.active.id)
    else this.active = null
  },

  destroyed() {
    this.boundBox?.removeEventListener("mousedown", this.onMentionPick)
    this.boundBox?.removeEventListener("dragover", this.onDragOver)
    this.boundBox?.removeEventListener("dragleave", this.onDragLeave)
    this.boundBox?.removeEventListener("drop", this.onDrop)
    this.boundForm?.removeEventListener("submit", this.onSubmit)
  },

  box() {
    return this.el.closest("[data-composer-box], .composer-box") || this.el.form || this.el.parentElement
  },

  picker() {
    return (this.el.form || this.box())?.querySelector("input[type=file]") || null
  },

  submit() {
    const form = this.el.form
    if (!form) return
    const picker = this.picker()
    const held = picker?.files?.length ?? 0
    // A prompt of nothing but a screenshot is a real prompt: "look at this"
    // is most of what somebody wants to say about a picture.
    if (!this.el.value.trim() && held === 0) return
    if (this.el.disabled) return
    form.requestSubmit()
  },

  grow() {
    this.el.style.height = "auto"
    this.el.style.height = `${Math.min(this.el.scrollHeight, CEILING)}px`
  },

  // Files from a paste, a drop or the picker are the same gesture. Nothing
  // is filtered on the way in: a dropped PDF is a person who meant something
  // by it, and telling them it is not an image they can attach is a better
  // answer than a drop that appears to do nothing at all.
  attach(files) {
    const incoming = Array.from(files ?? [])
    if (!incoming.length) return false
    if (this.el.dataset.mode === "comment") {
      this.note("Comments are text only. Switch to Ask agent to attach images.")
      return true
    }
    const picker = this.picker()
    if (!picker) return false
    const held = picker.files?.length ?? 0
    const {accepted, rejected} = accept(incoming, held)
    this.note(rejectionMessage(rejected))
    if (!accepted.length) return rejected.length > 0
    const transfer = new DataTransfer()
    for (const file of picker.files ?? []) transfer.items.add(file)
    for (const file of accepted) transfer.items.add(file)
    picker.files = transfer.files
    // LiveView listens for the input's own events to start the upload.
    picker.dispatchEvent(new Event("input", {bubbles: true}))
    picker.dispatchEvent(new Event("change", {bubbles: true}))
    return true
  },

  /** The listbox of people, while the box is in Comment mode. */
  mentions() {
    if (this.el.dataset.mode !== "comment") return null
    const id = this.el.getAttribute("aria-controls")
    return (id && document.getElementById(id)) || null
  },

  /** Open, filter or close the list for whatever `@` is at the caret. */
  mention() {
    const menu = this.mentions()
    const query = menu && mentionQuery(this.el.value, this.el.selectionStart ?? this.el.value.length)
    if (!query) return this.closeMentions()
    const prefix = query.query.toLowerCase()
    let first = null
    for (const option of menu.querySelectorAll("[role=option]")) {
      const hit = option.dataset.login.toLowerCase().startsWith(prefix)
      option.hidden = !hit
      if (hit && !first) first = option
    }
    if (!first) return this.closeMentions()
    menu.setAttribute("data-open", "")
    this.highlight(first)
  },

  /** Arrow keys, Enter, Tab and Escape while the list is open. True if handled. */
  mentionKey(e) {
    const menu = this.mentions()
    if (!menu?.hasAttribute("data-open") || e.isComposing) return false
    const shown = Array.from(menu.querySelectorAll("[role=option]")).filter(o => !o.hidden)
    const at = shown.indexOf(this.active)
    if (e.key === "ArrowDown") this.highlight(shown[(at + 1) % shown.length])
    else if (e.key === "ArrowUp") this.highlight(shown[(at - 1 + shown.length) % shown.length])
    else if ((e.key === "Enter" && !e.shiftKey) || e.key === "Tab") this.choose(this.active ?? shown[0])
    else if (e.key === "Escape") this.closeMentions()
    else return false
    return true
  },

  highlight(option) {
    if (this.active) this.active.setAttribute("aria-selected", "false")
    this.active = option
    option.setAttribute("aria-selected", "true")
    option.scrollIntoView?.({block: "nearest"})
    this.el.setAttribute("aria-activedescendant", option.id)
  },

  choose(option) {
    const caret = this.el.selectionStart ?? this.el.value.length
    const query = mentionQuery(this.el.value, caret)
    if (query) {
      const text = `@${option.dataset.login} `
      this.el.value = this.el.value.slice(0, query.start) + text + this.el.value.slice(caret)
      const after = query.start + text.length
      this.el.setSelectionRange?.(after, after)
      this.save()
      this.grow()
    }
    this.closeMentions()
    this.el.focus()
  },

  closeMentions() {
    const menu = this.mentions()
    menu?.removeAttribute("data-open")
    if (this.active) this.active.setAttribute("aria-selected", "false")
    this.active = null
    this.el.removeAttribute("aria-activedescendant")
  },

  note(text) {
    const el = this.box().querySelector("[data-composer-note]")
    if (!el) return
    el.textContent = text ?? ""
    el.hidden = !text
  },

  typing() {
    const event = this.el.dataset.typingEvent
    if (!event) return
    const now = Date.now()
    if (now - this.lastTyping < TYPING_EVERY) return
    this.lastTyping = now
    this.pushEvent(event, {})
  },

  restore() {
    if (!this.key || this.el.value) return
    try {
      const draft = localStorage.getItem(this.key)
      if (draft) {
        this.el.value = draft
        this.el.dataset.dirty = "true"
      }
    } catch {
      // No storage, no draft; the box still works.
    }
  },

  save() {
    if (!this.key) return
    try {
      if (this.el.value) {
        localStorage.setItem(this.key, this.el.value)
        this.el.dataset.dirty = "true"
      } else {
        this.forget()
      }
    } catch {
      // The words are still in the box.
    }
  },

  forget() {
    delete this.el.dataset.dirty
    if (!this.key) return
    try {
      localStorage.removeItem(this.key)
    } catch {
      // Nothing to forget.
    }
  },
}

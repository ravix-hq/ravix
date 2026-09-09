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
      if (this.el.value.trim()) this.typing()
    })
    this.el.addEventListener("keydown", e => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
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
    box.addEventListener("dragover", this.onDragOver)
    box.addEventListener("dragleave", this.onDragLeave)
    box.addEventListener("drop", this.onDrop)

    const form = this.el.form
    this.onSubmit = () => this.forget()
    form?.addEventListener("submit", this.onSubmit)

    this.handleEvent("composer:clear", () => {
      this.el.value = ""
      this.forget()
      this.grow()
      this.note(null)
    })
  },

  updated() {
    this.grow()
  },

  destroyed() {
    const box = this.box()
    box.removeEventListener("dragover", this.onDragOver)
    box.removeEventListener("dragleave", this.onDragLeave)
    box.removeEventListener("drop", this.onDrop)
    this.el.form?.removeEventListener("submit", this.onSubmit)
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

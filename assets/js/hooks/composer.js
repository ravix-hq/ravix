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
// In Ask mode the same kind of list, `[data-composer-suggestions]`, is
// filled here rather than by the server. `@` searches the track's files: the
// first `@` pushes `data-files-event` and the server answers with
// `composer:files` (`{paths, truncated, error}`), and the paths are ranked
// here as the person types, so a keystroke is not a round trip. `/` as the
// first thing in the message offers `data-commands`, a JSON list the server
// renders: the agent's own commands, which choosing puts in the box to be
// sent, and a few Ravix actions (`event`, `value`), which choosing runs
// instead. A `/` that matches nothing is just text and sends as text. What
// the list shows is said in `[data-composer-announce]`, a polite live
// region, because a highlighted option is only announced once it is moved
// to and "is there anything?" is the question before that.
//
// ⌘L (Ctrl+L off a Mac) focuses the box from anywhere on the page except
// the terminal, where Ctrl+L already means "clear the screen".
//
// Ask agent / Comment (`[data-composer-mode]` buttons in the box) switch
// here the moment they are pressed (RAV-94): the box's colour, the pressed
// button, the placeholder (`data-placeholder-ask`, `data-placeholder-comment`)
// and the accessible names. The button's `phx-click` still tells the server,
// whose render is the truth: `data-mode` is only ever what it rendered, and
// until it renders the mode chosen here, a patch that arrives first (and so
// puts back the old look) has the chosen look put back over it.
//
// Sending clears the remembered draft; the text itself stays until the
// server says the prompt was saved, by pushing `composer:clear` to this
// hook. A save that fails leaves the words where they were, which is the
// point: a composer that eats a paragraph on a network blip is unforgivable
// in a way a visible error is not.

const CEILING = 260
const DRAFT_PREFIX = "ravix.draft."
const TYPING_EVERY = 1500
/** How many files the `@` list shows at once. Typing more narrows it. */
const SHOWN = 50
/** What the `@` list says, beside a spinner, until the files arrive. */
const SEARCHING = "Searching files…"
/** How long a mode chosen here outlasts a server that never renders it. */
const MODE_PATIENCE = 10_000

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

/** The `@path` being typed just before the caret, or null. */
export function fileQuery(text, caret) {
  const match = /(^|[\s([{"'])@([^\s@`"']{0,200})$/.exec(text.slice(0, caret))
  return match ? {start: caret - match[2].length - 1, query: match[2]} : null
}

/** The `/command` being typed as the whole message so far, or null. */
export function commandQuery(text, caret) {
  const match = /^\/([A-Za-z0-9_:.-]{0,64})$/.exec(text.slice(0, caret))
  return match ? {start: 0, query: match[1]} : null
}

/**
 * The query's characters found in order in `text`, or null: a score (higher
 * is better; runs and the starts of words and path segments earn more) and
 * the indices matched, for underlining. The whole query in one piece is
 * preferred wherever it occurs -- at a boundary, and nearest the end, which
 * in a path is the file's name -- over letters picked up from left to right.
 */
export function fuzzy(query, text) {
  const q = query.toLowerCase()
  const t = text.toLowerCase()
  const boundary = at => at === 0 || "/._- ".includes(t[at - 1])
  let whole = -1
  for (let at = t.indexOf(q); q && at >= 0; at = t.indexOf(q, at + 1)) {
    if (whole < 0 || boundary(at) || !boundary(whole)) whole = at
  }
  const marks = []
  if (whole >= 0) {
    for (let i = 0; i < q.length; i++) marks.push(whole + i)
  } else {
    let from = 0
    for (const ch of q) {
      const at = t.indexOf(ch, from)
      if (at < 0) return null
      marks.push(at)
      from = at + 1
    }
  }
  const score = marks.reduce((sum, at, i) => sum + 1 + (at === marks[i - 1] + 1 ? 4 : 0) + (boundary(at) ? 3 : 0), 0)
  return {score, marks}
}

/** The best `limit` of `paths` for `query`, each `{path, marks}`. */
export function rankFiles(query, paths, limit = SHOWN) {
  if (!query) return paths.slice(0, limit).map(path => ({path, marks: []}))
  const q = query.toLowerCase()
  const ranked = []
  paths.forEach((path, order) => {
    const hit = fuzzy(query, path)
    if (!hit) return
    const base = path.slice(path.lastIndexOf("/") + 1).toLowerCase()
    // The name is what people remember; where it lives is a tiebreak.
    const bonus = (base.startsWith(q) ? 30 : base.includes(q) ? 20 : 0) + (path.toLowerCase().includes(q) ? 10 : 0)
    ranked.push({path, marks: hit.marks, score: hit.score + bonus, order})
  })
  ranked.sort((a, b) => b.score - a.score || a.path.length - b.path.length || a.order - b.order)
  return ranked.slice(0, limit).map(({path, marks}) => ({path, marks}))
}

/** Commands for `query`: names that start with it first, then any that contain it in order. */
export function rankCommands(query, commands) {
  if (!query) return commands.map(command => ({command, marks: []}))
  const q = query.toLowerCase()
  const starts = []
  const others = []
  for (const command of commands) {
    const hit = fuzzy(q, command.name)
    if (!hit) continue
    ;(command.name.toLowerCase().startsWith(q) ? starts : others).push({command, marks: hit.marks})
  }
  return starts.concat(others)
}

// Abbreviations whose full stop does not end a sentence.
const NOT_AN_END = /\b(?:e\.g|i\.e|etc|vs|cf)\.$/i

/**
 * A command's own one-line purpose, from its description (RAV-95). Skills
 * describe themselves to the model ("Use this skill when users are...") and
 * the list is for a person, so: the first sentence, without a leading "Use
 * this skill when", "Use this when" or "Use when", capitalised. Nothing is
 * made up; with nothing left, the command's name.
 */
export function purpose(description, name) {
  const text = String(description ?? "").replace(/\s+/g, " ").trim()
  let first = text
  for (const end of text.matchAll(/[.!?](?=\s|$)/g)) {
    const upTo = text.slice(0, end.index + 1)
    if (!NOT_AN_END.test(upTo)) {
      first = upTo
      break
    }
  }
  const rest = first
    .replace(/^use (?:this skill |this )?when\b[\s,:;-]*/i, "")
    .replace(/[.!?]$/, "")
    .trim()
  if (!/[\p{L}\p{N}]/u.test(rest)) return name
  return rest[0].toUpperCase() + rest.slice(1)
}

/**
 * Bring `option` into view inside `list` and nowhere else. `scrollIntoView`
 * scrolls every scroller around it too, and the list floats over the
 * transcript: opening it must not move what somebody is reading (RAV-95).
 */
function reveal(list, option) {
  if (!list || !option) return
  const top = option.offsetTop
  const bottom = top + option.offsetHeight
  if (top < list.scrollTop) list.scrollTop = top
  else if (bottom > list.scrollTop + list.clientHeight) list.scrollTop = bottom - list.clientHeight
}

/** ⌘L on a Mac, Ctrl+L elsewhere. */
export function shortcutLabel(platform = navigator.userAgentData?.platform || navigator.platform || "") {
  return /mac|iphone|ipad/i.test(platform) ? "⌘L" : "Ctrl+L"
}

function itemKey(item) {
  return item.command ? `/${item.command.name}` : item.path
}

function count(n, one, many) {
  return `${n.toLocaleString("en")} ${n === 1 ? one : many}`
}

/** `text` as spans, with the characters at `marks` in `<mark>`. Never HTML. */
function marked(el, text, marks, offset = 0) {
  const at = new Set(marks.map(m => m - offset))
  let run = ""
  const flush = () => {
    if (run) el.append(document.createTextNode(run))
    run = ""
  }
  for (let i = 0; i < text.length; i++) {
    if (!at.has(i)) {
      run += text[i]
      continue
    }
    flush()
    const mark = document.createElement("mark")
    mark.textContent = text[i]
    el.append(mark)
  }
  flush()
  return el
}

function list(names) {
  if (names.length <= 1) return names[0] ?? ""
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`
}

export const Composer = {
  mounted() {
    this.key = this.el.dataset.draftKey ? DRAFT_PREFIX + this.el.dataset.draftKey : null
    this.lastTyping = 0
    // What `@` searches: null until asked for, then `{paths, truncated,
    // error}`; `filesAsked` so one `@` asks once, however fast it is typed.
    this.files = null
    this.filesAsked = false
    this.suggestion = null
    this.restore()
    this.grow()
    this.reportEmpty(true)

    this.el.addEventListener("input", () => {
      this.grow()
      this.reportEmpty()
      this.save()
      this.mention()
      this.suggest()
      if (this.el.value.trim()) this.typing()
    })
    // A patch that moves the box blurs it for a moment and LiveView puts the
    // focus back in the same task, so only a blur that lasts closes the list.
    this.el.addEventListener("blur", () => {
      setTimeout(() => {
        if (document.activeElement !== this.el) this.closeSuggestions()
      })
    })
    this.el.addEventListener("keydown", e => {
      if (this.suggestionKey(e) || this.mentionKey(e)) {
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
      const suggestion = e.target.closest?.("[data-composer-suggestions] [role=option]")
      if (suggestion) {
        e.preventDefault()
        if (suggestion.getAttribute("aria-disabled") !== "true") this.pick(Number(suggestion.dataset.index))
        return
      }
      // The list's own padding or edge: the caret stays in the box.
      if (e.target.closest?.("[data-composer-suggestions]")) {
        e.preventDefault()
        return
      }
      const option = e.target.closest?.("[data-mention-options] [role=option]")
      if (!option) return
      // Keep the caret in the box: the choice is made on the way down.
      e.preventDefault()
      this.choose(option)
    }
    this.onModeClick = e => {
      const button = e.target.closest?.("[data-composer-mode]")
      if (button) this.chooseMode(button.dataset.composerMode)
    }
    this.boundBox = box
    box.addEventListener("click", this.onModeClick)
    box.addEventListener("mousedown", this.onMentionPick)
    box.addEventListener("dragover", this.onDragOver)
    box.addEventListener("dragleave", this.onDragLeave)
    box.addEventListener("drop", this.onDrop)

    this.boundForm = this.el.form
    this.onSubmit = () => this.save()
    this.boundForm?.addEventListener("submit", this.onSubmit)

    this.onShortcut = e => {
      if (e.key?.toLowerCase() !== "l" || !(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey) return
      if (e.target.closest?.(".xterm, [phx-hook=Terminal]")) return
      if (this.el.disabled || !this.el.isConnected) return
      e.preventDefault()
      this.el.focus()
      const end = this.el.value.length
      this.el.setSelectionRange?.(end, end)
    }
    document.addEventListener("keydown", this.onShortcut)
    const hint = document.querySelector("[data-composer-shortcut]")
    if (hint) {
      const kbd = document.createElement("kbd")
      kbd.textContent = shortcutLabel()
      hint.replaceChildren(kbd, " to focus")
    }

    this.handleEvent("composer:files", ({paths, truncated, error}) => {
      this.files = {
        paths: Array.isArray(paths) ? paths : [],
        truncated: truncated === true,
        error: error || null,
        // A failed read is asked again by the next `@`, not by every key.
        at: this.suggestion?.start,
      }
      if (error) this.filesAsked = false
      if (this.suggestion?.kind === "files") this.suggest()
    })

    this.handleEvent("composer:insert", ({text}) => {
      this.el.value = text
      this.reportEmpty()
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
      this.reportEmpty()
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
      this.reportEmpty()
      this.forget()
      this.grow()
      this.note(null)
    })
  },

  updated() {
    this.reconcileMode()
    this.restore()
    this.grow()
    this.reportEmpty()
    // A patch rewrites the attributes, and may have brought new commands.
    if (this.suggestion) this.suggest()
    // A patch rewrites the textarea's attributes from the template, which
    // does not know which option is highlighted.
    if (this.active && this.mentions()) this.el.setAttribute("aria-activedescendant", this.active.id)
    else this.active = null
  },

  // A new socket is a new page process, which starts out believing the box
  // is empty; tell it otherwise.
  reconnected() {
    this.reportEmpty(true)
  },

  destroyed() {
    document.removeEventListener("keydown", this.onShortcut)
    this.boundBox?.removeEventListener("click", this.onModeClick)
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
    if (this.mode() === "comment") {
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
    if (this.mode() !== "comment") return null
    const id = this.el.getAttribute("aria-controls")
    const el = id && document.getElementById(id)
    return el?.hasAttribute("data-mention-options") ? el : null
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
    reveal(this.mentions(), option)
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

  /** Ask or comment: the one chosen here, until the server has drawn it. */
  mode() {
    return this.pendingMode?.mode ?? this.el.dataset.mode
  },

  chooseMode(mode) {
    if (!this.el.dataset.mode || !["ask", "comment"].includes(mode)) return
    // Closed while the mode they belong to is still the one in force.
    this.closeSuggestions()
    this.closeMentions()
    // Back to the drawn mode before the server has drawn the other one: it
    // will, so this waits for the server to draw this one again after it.
    const settled = mode === this.el.dataset.mode && !this.pendingMode
    this.pendingMode = settled ? null : {mode, at: Date.now()}
    this.showMode(mode)
  },

  // After a patch: the server has drawn the chosen mode, or drawn the old
  // one over it (a patch it sent before the click arrived), or given up.
  reconcileMode() {
    const pending = this.pendingMode
    if (!pending) return
    if (pending.mode === this.el.dataset.mode || Date.now() - pending.at > MODE_PATIENCE) {
      this.pendingMode = null
    } else {
      this.showMode(pending.mode)
    }
  },

  showMode(mode) {
    const comment = mode === "comment"
    const box = this.box()
    box.classList.toggle("commenting", comment)
    for (const button of box.querySelectorAll("[data-composer-mode]")) {
      button.setAttribute("aria-pressed", String(button.dataset.composerMode === mode))
    }
    const placeholder = comment ? this.el.dataset.placeholderComment : this.el.dataset.placeholderAsk
    if (placeholder) this.el.placeholder = placeholder
    this.el.setAttribute("aria-label", comment ? "Comment" : "Message")
    // A Read member cannot ask, but can comment.
    this.el.disabled = !comment && this.el.dataset.askDisabled === "true"
    const send = box.querySelector(".composer-send")
    if (send) {
      const label = comment ? "Post comment" : "Send"
      send.setAttribute("aria-label", label)
      send.title = label
    }
  },

  /** Ask mode's list, if this box has one. */
  suggestions() {
    if (this.mode() === "comment") return null
    const id = this.el.getAttribute("aria-controls")
    const el = id && document.getElementById(id)
    return el?.hasAttribute("data-composer-suggestions") ? el : null
  },

  commands() {
    try {
      const parsed = JSON.parse(this.el.dataset.commands || "[]")
      return Array.isArray(parsed) ? parsed.filter(c => typeof c?.name === "string") : []
    } catch {
      return []
    }
  },

  /** Open, refresh or close the `/` or `@` list for what is at the caret. */
  suggest() {
    const menu = this.suggestions()
    if (!menu) return
    const caret = this.el.selectionStart ?? this.el.value.length
    const command = this.el.dataset.commands ? commandQuery(this.el.value, caret) : null
    const file = !command && this.el.dataset.filesEvent ? fileQuery(this.el.value, caret) : null
    const found = command ? {kind: "commands", ...command} : file ? {kind: "files", ...file} : null
    if (!found) {
      this.dismissed = null
      return this.closeSuggestions()
    }
    // Escape closed this one; the next `@` or `/` opens again.
    if (this.dismissed === `${found.kind}:${found.start}`) return this.closeSuggestions()
    this.dismissed = null

    let items = []
    let status = null
    if (found.kind === "commands") {
      items = rankCommands(found.query, this.commands())
      if (!items.length) return this.closeSuggestions()
    } else if (!this.files || (this.files.error && this.files.at !== found.start)) {
      if (this.files) this.files = null
      if (!this.filesAsked) {
        this.filesAsked = true
        this.pushEvent(this.el.dataset.filesEvent, {})
      }
      status = SEARCHING
    } else if (this.files.error) {
      status = this.files.error
    } else {
      items = rankFiles(found.query, this.files.paths)
      if (!items.length) status = found.query ? "No files match" : "No files in this track yet"
    }
    const same = this.suggestion?.kind === found.kind && this.suggestion.start === found.start
    const keep = same && this.suggestion.items[this.suggestion.active]
    const active = keep ? Math.max(0, items.findIndex(i => itemKey(i) === itemKey(keep))) : 0
    this.suggestion = {...found, items, status, active: items.length ? active : -1}
    this.searching = status === SEARCHING
    this.renderSuggestions(menu)
  },

  renderSuggestions(menu) {
    const {kind, items, status, active} = this.suggestion
    const options = items.map((item, index) => {
      const li = document.createElement("li")
      li.id = `composer-suggestion-${index}`
      li.setAttribute("role", "option")
      li.setAttribute("aria-selected", String(index === active))
      li.dataset.index = String(index)
      if (kind === "files") {
        const cut = item.path.lastIndexOf("/") + 1
        const name = document.createElement("strong")
        marked(name, item.path.slice(cut), item.marks, cut)
        const dir = document.createElement("span")
        dir.className = "dim"
        marked(dir, item.path.slice(0, cut), item.marks.filter(m => m < cut))
        li.append(name, dir)
      } else {
        const name = document.createElement("strong")
        name.append("/")
        marked(name, item.command.name, item.marks)
        const about = document.createElement("span")
        about.className = "dim"
        const described = item.command.description && purpose(item.command.description, item.command.name)
        about.textContent = [described, item.command.hint && `(${item.command.hint})`]
          .filter(Boolean).join(" ")
        // The whole description is still there, for whoever wants it.
        if (item.command.description) li.title = item.command.description
        li.append(name, about)
        if (item.command.source === "ravix") {
          const source = document.createElement("span")
          source.className = "suggestion-source"
          source.textContent = "Ravix"
          li.append(source)
        }
      }
      return li
    })
    if (status || (kind === "files" && this.files?.truncated && items.length)) {
      const li = document.createElement("li")
      li.id = "composer-suggestion-status"
      li.setAttribute("role", "option")
      li.setAttribute("aria-disabled", "true")
      li.setAttribute("aria-selected", "false")
      if (this.searching) {
        const spinner = document.createElement("span")
        spinner.className = "suggestion-spinner"
        spinner.setAttribute("aria-hidden", "true")
        li.append(spinner)
      }
      li.append(status || "Not every file was searched. Type more of the path to narrow it.")
      options.push(li)
    }
    menu.replaceChildren(...options)
    menu.setAttribute("aria-label", kind === "files" ? "Files to mention" : "Commands")
    if (this.searching) menu.setAttribute("aria-busy", "true")
    else menu.removeAttribute("aria-busy")
    menu.hidden = false
    const current = options[active]
    if (current) {
      this.el.setAttribute("aria-activedescendant", current.id)
      reveal(menu, current)
    } else {
      this.el.removeAttribute("aria-activedescendant")
    }
    this.announce(status ??
      (kind === "files"
        ? `${count(items.length, "file", "files")}${items.length >= SHOWN ? " shown" : ""}. Up and down to choose, Enter to mention.`
        : `${count(items.length, "command", "commands")}. Up and down to choose, Enter to pick.`))
  },

  /** Arrow keys, Enter, Tab and Escape while the Ask list is open. True if handled. */
  suggestionKey(e) {
    if (!this.suggestion || e.isComposing) return false
    const {items, active} = this.suggestion
    const n = items.length
    if (e.key === "Escape") {
      this.dismissed = `${this.suggestion.kind}:${this.suggestion.start}`
      this.closeSuggestions()
    } else if (!n) {
      return false
    } else if (e.key === "ArrowDown") {
      this.move((active + 1) % n)
    } else if (e.key === "ArrowUp") {
      this.move((active - 1 + n) % n)
    } else if ((e.key === "Enter" && !e.shiftKey) || e.key === "Tab") {
      this.pick(active)
    } else {
      return false
    }
    return true
  },

  move(index) {
    this.suggestion.active = index
    this.renderSuggestions(this.suggestions())
  },

  pick(index) {
    const item = this.suggestion?.items[index]
    if (!item) return
    const {start} = this.suggestion
    const caret = this.el.selectionStart ?? this.el.value.length
    const before = this.el.value.slice(0, start)
    const after = this.el.value.slice(caret)
    this.closeSuggestions()
    if (item.command?.event) {
      // A Ravix action is a button, not a message: the `/word` goes.
      this.el.value = before + after.replace(/^ /, "")
      this.el.setSelectionRange?.(before.length, before.length)
      this.pushEvent(item.command.event, item.command.value || {})
    } else {
      const text = item.command ? `/${item.command.name} ` : `@${item.path} `
      this.el.value = before + text + after
      this.el.setSelectionRange?.(before.length + text.length, before.length + text.length)
      this.announce(item.command ? `/${item.command.name} added.` : `${item.path} mentioned.`)
    }
    this.save()
    this.grow()
    this.el.focus()
  },

  closeSuggestions() {
    if (!this.suggestion) return
    this.suggestion = null
    const menu = this.suggestions()
    if (menu) menu.hidden = true
    menu?.replaceChildren()
    menu?.removeAttribute("aria-busy")
    this.el.removeAttribute("aria-activedescendant")
  },

  announce(text) {
    const el = this.box().querySelector("[data-composer-announce]")
    if (el && el.textContent !== text) el.textContent = text
  },

  note(text) {
    const el = this.box().querySelector("[data-composer-note]")
    if (!el) return
    el.textContent = text ?? ""
    el.hidden = !text
  },

  // RAV-87: the server draws send and Stop from whether this box is empty,
  // which it cannot see --- the text only travels on submit --- so it is
  // told when that changes, and never per keystroke. Whitespace is empty.
  reportEmpty(force = false) {
    const event = this.el.dataset.emptyEvent
    if (!event) return
    const empty = !this.el.value.trim()
    if (!force && empty === this.reportedEmpty) return
    this.reportedEmpty = empty
    this.pushEvent(event, {empty})
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

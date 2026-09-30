// An interactive terminal: a real shell on the track's machine, drawn by
// xterm.js.
//
// The Commands tab (`terminal.js`) is a command in and a result out; this is
// the other thing a terminal is, a pseudo-terminal whose every keystroke goes
// to the machine and whose every byte comes back, so `iex -S mix`, `psql` and
// `vim` work. The server holds the socket to the machine
// (`Ravix.Terminal.Shell`); this hook only draws and types. What it expects:
//
//   <div id="shell-{id}" phx-hook="Shell" phx-update="ignore" phx-target={@myself}
//        data-id={id} data-label="Terminal 1"
//        data-xterm-js="/assets/js/xterm.js" data-xterm-css="/assets/js/xterm.css"></div>
//
// Events pushed:
//
//   "shell-attach"  {id, cols, rows,   to the component, once measured, and again
//                    select}           on a reconnect or a `ravix:shell-reattach`;
//                                      `select` puts the pane back in front after
//                                      a reconnect if it was in front before
//   "shell-input"   {id, data}         to the page, for every keystroke or paste
//   "shell-resize"  {id, cols, rows}   to the page, when the pane's size differs
//                                      from the one the shell was last given
//
// A new shell draws its first prompt at the size in `shell-attach`, so the
// pane is measured only once it is really laid out: xterm's stylesheet
// applied, the monospace font loaded, and a frame drawn. Measured any sooner
// it attaches at one width, is refitted to another a moment later, and the
// shell redraws its prompt for the new width under the first one.
//
// Events handled, for every pane on the page, so each checks the id:
//
//   "shell:output"  {id, data}   base64 bytes, written as they are (UTF-8 is
//                                decoded by xterm, across chunk boundaries)
//   "shell:reset"   {id}         a fresh attachment is about to replay the
//                                shell's output from the start
//
// xterm.js is about 300 KB, so it is its own bundle, loaded the first time a
// terminal is opened rather than on every page (`assets/js/xterm.js`).
// Colours come from the theme's custom properties and follow a theme change.

/** Keystrokes and pastes waiting to be sent, flushed on the next frame. */
const INPUT_FLUSH_MS = 8
const RESIZE_SETTLE_MS = 80
/** How long a pane waits for xterm's stylesheet before measuring anyway. */
const STYLE_WAIT_MS = 3_000
/** How long a pane that was in front is remembered across its page remounting. */
const FRONT_MS = 15_000
const FRONT_KEY = "ravix.shell.front"

let loading = null

/** The xterm bundle: `{Terminal, FitAddon}`, loaded once per page. */
export function loadXterm(src, css, doc = document) {
  if (window.RavixXterm) return Promise.resolve(window.RavixXterm)
  if (loading) return loading
  loading = new Promise((resolve, reject) => {
    if (css && !doc.querySelector("link[data-xterm]")) {
      const link = doc.createElement("link")
      link.rel = "stylesheet"
      link.href = css
      link.dataset.xterm = ""
      // Settled either way, for the panes that ask `xtermStyles` later.
      link.onload = link.onerror = () => (link.dataset.settled = "")
      doc.head.appendChild(link)
    }
    const script = doc.createElement("script")
    script.src = src
    script.onload = () => (window.RavixXterm ? resolve(window.RavixXterm) : reject(new Error("xterm did not load")))
    script.onerror = () => reject(new Error("xterm did not load"))
    doc.head.appendChild(script)
  }).finally(() => {
    // Only a load in flight is shared; once settled, `window.RavixXterm` is
    // the answer, and a failure is tried again by the next pane.
    loading = null
  })
  return loading
}

/**
 * xterm's stylesheet, applied (or given up on) before xterm is measured: the
 * fit addon measures elements that stylesheet lays out.
 */
export function xtermStyles(doc = document, wait = STYLE_WAIT_MS) {
  const link = doc.querySelector("link[data-xterm]")
  if (!link || link.sheet || link.dataset.settled !== undefined) return Promise.resolve()
  return new Promise(resolve => {
    const done = () => {
      clearTimeout(timer)
      resolve()
    }
    const timer = setTimeout(done, wait)
    link.addEventListener("load", done, {once: true})
    link.addEventListener("error", done, {once: true})
  })
}

/** After the next frame is laid out, where there are frames. */
export function laidOut() {
  return new Promise(resolve => (typeof requestAnimationFrame === "function" ? requestAnimationFrame(() => resolve()) : setTimeout(resolve, 0)))
}

/** The theme's monospace font, loaded (or given up on) before xterm measures it. */
export function monoFont(el) {
  const family = getComputedStyle(el).getPropertyValue("--mono").trim()
  if (!family || !document.fonts?.load) return Promise.resolve()
  return document.fonts.load(`12px ${family}`).catch(() => {})
}

/** Base64 to bytes, without a detour through a string xterm would re-decode. */
export function decode(data) {
  const binary = atob(data)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

/** The xterm theme, from the palette the page is painted in. */
export function theme(el) {
  const style = getComputedStyle(el)
  const v = name => style.getPropertyValue(name).trim() || undefined
  return {
    background: v("--code-bg"),
    foreground: v("--ink"),
    cursor: v("--accent"),
    cursorAccent: v("--code-bg"),
    selectionBackground: v("--accent-soft"),
    red: v("--bad"),
    green: v("--ok"),
    yellow: v("--warn"),
    blue: v("--accent"),
    brightBlack: v("--dimmer"),
  }
}

export const Shell = {
  mounted() {
    this.id = this.el.dataset.id
    this.pending = ""
    this.onReattach = () => this.attach()
    this.el.addEventListener("ravix:shell-reattach", this.onReattach)

    // Registered before the bundle arrives, so nothing the server sends in
    // the meantime is lost: it waits for the terminal to exist.
    this.backlog = []
    this.handleEvent("shell:output", ({id, data}) => {
      if (id !== this.id) return
      if (this.term) this.term.write(decode(data))
      else this.backlog.push(data)
    })
    this.handleEvent("shell:reset", ({id}) => {
      if (id !== this.id) return
      this.backlog = []
      this.term?.reset()
    })

    // xterm measures a character cell once, when it opens. Opened before the
    // theme's monospace font has loaded, it measures the fallback font's, and
    // the real glyphs then overrun their cells.
    const xterm = loadXterm(this.el.dataset.xtermJs, this.el.dataset.xtermCss).then(loaded => xtermStyles().then(() => loaded))
    Promise.all([xterm, monoFont(this.el)]).then(
      ([loaded]) => this.start(loaded),
      () => {
        if (!this.gone) this.el.textContent = "The terminal could not be loaded. Reload the page to try again."
      },
    )
  },

  start({Terminal, FitAddon}) {
    if (this.gone) return
    const style = getComputedStyle(this.el)
    const term = new Terminal({
      cursorBlink: true,
      fontFamily: style.getPropertyValue("--mono").trim() || "monospace",
      fontSize: 12,
      lineHeight: 1.2,
      scrollback: 5000,
      theme: theme(this.el),
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(this.el)
    term.textarea?.setAttribute("aria-label", this.el.dataset.label || "Terminal")
    this.term = term
    this.fit = fit

    term.onData(data => this.type(data))
    term.onResize(({cols, rows}) => {
      clearTimeout(this.resizeTimer)
      this.resizeTimer = setTimeout(() => this.resize(cols, rows), RESIZE_SETTLE_MS)
    })

    this.observer = new ResizeObserver(() => this.refit())
    this.observer.observe(this.el)
    this.themeObserver = new MutationObserver(() => (term.options.theme = theme(this.el)))
    this.themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme", "style"]})

    for (const data of this.backlog.splice(0)) term.write(decode(data))
    const front = this.wasInFront()
    laidOut().then(() => {
      if (this.gone) return
      this.refit()
      this.attach(front)
      if (this.visible) term.focus()
    })
  },

  // A hidden pane measures as nothing; it keeps the size it had until shown.
  // Being shown is also when it takes the keyboard: that is choosing its tab.
  refit() {
    const visible = Boolean(this.fit) && !this.el.closest("[hidden]")
    const shown = visible && this.visible === false
    if (!visible && this.visible) this.hiddenAt = this.viewport()
    this.visible = visible
    if (!visible) return
    try {
      this.fit.fit()
    } catch {
      // Not laid out yet; the observer will call again when it is.
    }
    if (shown) {
      this.restoreScroll()
      this.term.focus()
    }
  },

  // Where the view was when the pane was hidden: following the output, or
  // on a line somebody scrolled back to.
  viewport() {
    const buffer = this.term?.buffer?.active
    return buffer ? {atBottom: buffer.viewportY >= buffer.baseY, line: buffer.viewportY} : null
  },

  // A hidden pane's viewport has no height, so the browser shows it again
  // from the top: a pane opened behind another tab, or written to while
  // there (a reload's replayed scrollback), would open on its first rows.
  // Put the view back once the writes still being parsed have landed and
  // the pane has laid out --- at the end, unless it was scrolled back.
  restoreScroll() {
    const saved = this.hiddenAt
    this.hiddenAt = null
    this.term.write("", () =>
      requestAnimationFrame(() => {
        if (this.gone || !this.term) return
        if (saved && !saved.atBottom) this.term.scrollToLine(saved.line)
        else this.term.scrollToBottom()
      }),
    )
  },

  attach(select = false) {
    if (!this.term) return
    const {cols, rows} = this.term
    this.sent = {cols, rows}
    this.pushEventTo(this.el, "shell-attach", {id: this.id, cols, rows, select})
  },

  // Only a size the shell does not already have: the same size again would
  // only make it redraw its prompt.
  resize(cols, rows) {
    if (this.sent?.cols === cols && this.sent?.rows === rows) return
    this.sent = {cols, rows}
    this.pushEvent("shell-resize", {id: this.id, cols, rows})
  },

  // Keystrokes are batched into one event per few milliseconds: a paste or a
  // held key is then one message to the server, not one per character.
  type(data) {
    this.pending += data
    if (this.inputTimer) return
    this.inputTimer = setTimeout(() => {
      this.inputTimer = null
      const data = this.pending
      this.pending = ""
      if (data) this.pushEvent("shell-input", {id: this.id, data})
    }, INPUT_FLUSH_MS)
  },

  // A reconnect gives the track a new page process, which starts with the
  // dock closed and has no attachment until asked for one. The track page is
  // nested, so LiveView remounts it --- this pane is destroyed and a new one
  // mounted in its place --- and the note below is how the new pane knows it
  // was the one in front. `reconnected()` covers a page that is not nested.
  disconnected() {
    this.shownWhenDisconnected = this.visible === true
  },

  reconnected() {
    this.attach(this.shownWhenDisconnected)
  },

  wasInFront() {
    try {
      const note = JSON.parse(sessionStorage.getItem(FRONT_KEY) || "null")
      if (note?.id !== this.id) return false
      sessionStorage.removeItem(FRONT_KEY)
      return Date.now() - note.at < FRONT_MS
    } catch {
      return false
    }
  },

  destroyed() {
    if (this.visible) {
      try {
        sessionStorage.setItem(FRONT_KEY, JSON.stringify({id: this.id, at: Date.now()}))
      } catch {
        // Storage is off; the tab simply is not put back in front.
      }
    }
    this.gone = true
    clearTimeout(this.inputTimer)
    clearTimeout(this.resizeTimer)
    this.el.removeEventListener("ravix:shell-reattach", this.onReattach)
    this.observer?.disconnect()
    this.themeObserver?.disconnect()
    this.term?.dispose()
  },
}

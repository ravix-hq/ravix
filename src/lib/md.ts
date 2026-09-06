/**
 * Markdown, as an agent actually writes it, and while it is still writing.
 *
 * A coding agent's reply is markdown — headings, bullets, fenced code, a path
 * in backticks — and rendering it as `white-space: pre-wrap` throws all of
 * that away. What is left reads as a wall of text with stray asterisks in it,
 * which is the whole of the difference between "the machine is working" and
 * "some generic chat app is echoing something".
 *
 * No dependency: this is mission-control's renderer with the two things a
 * *live* transcript needs, and it is small enough that both are cheaper to
 * write than to import.
 *
 *   Streaming. Every call gets the reply *so far*, so the last construct on
 *   the page is nearly always half-arrived. An unterminated fence renders as
 *   an open code block rather than swallowing the rest of the turn, a blank
 *   line does not close a list that is about to continue, and a partial
 *   `**bo` renders as its own literal text and becomes bold when the closing
 *   pair lands.
 *
 *   Safety. Escape first, always. The bytes here came off a machine running
 *   somebody's repository, and the only markup in the output is markup this
 *   file put there. Links are rewritten only for `http(s)`, so no
 *   `javascript:` target can be spelled.
 */

interface Level {
  ordered: boolean;
  /** the indent that opened it, so a deeper bullet nests instead of restarting */
  indent: number;
  itemOpen: boolean;
}

export function renderMarkdown(src: string): string {
  const lines = src.replace(/\r\n/g, "\n").split("\n");
  const out: string[] = [];
  const lists: Level[] = [];
  let para: string[] = [];
  let quote: string[] = [];
  let fence: { lang: string; lines: string[] } | null = null;
  // A blank line between two bullets is a *loose* list, not the end of one.
  // Closing on the blank would restart `<ol>` numbering at 1 on every item,
  // which is exactly how agents write a numbered plan.
  let blank = false;

  const flushPara = () => {
    if (para.length) out.push(`<p>${inline(para.join(" "))}</p>`);
    para = [];
  };
  const flushQuote = () => {
    if (quote.length) out.push(`<blockquote><p>${inline(quote.join(" "))}</p></blockquote>`);
    quote = [];
  };
  const closeLists = (depth: number) => {
    while (lists.length > depth) {
      const level = lists.pop()!;
      if (level.itemOpen) out.push("</li>");
      out.push(level.ordered ? "</ol>" : "</ul>");
    }
  };
  const flushFence = () => {
    if (!fence) return;
    const cls = fence.lang ? ` class="lang-${escapeHtml(fence.lang)}"` : "";
    out.push(`<div class="code-block"><div class="code-block-toolbar"><button type="button" class="code-copy" aria-label="Copy code" aria-live="polite">Copy</button></div><pre><code${cls}>${escapeHtml(fence.lines.join("\n"))}</code></pre></div>`);
    fence = null;
  };
  const flushAll = () => {
    flushPara();
    flushQuote();
    closeLists(0);
  };

  for (const line of lines) {
    if (fence) {
      if (/^\s*```/.test(line)) flushFence();
      else fence.lines.push(line);
      continue;
    }

    const opening = line.match(/^\s*```\s*([\w+#.-]+)?/);
    if (opening) {
      flushAll();
      fence = { lang: opening[1] ?? "", lines: [] };
      blank = false;
      continue;
    }

    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    if (heading) {
      flushAll();
      const level = heading[1]!.length;
      out.push(`<h${level}>${inline(heading[2]!)}</h${level}>`);
      blank = false;
      continue;
    }

    if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
      flushAll();
      out.push("<hr />");
      blank = false;
      continue;
    }

    const item = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
    if (item) {
      flushPara();
      flushQuote();
      const indent = item[1]!.length;
      const ordered = !/^[-*+]$/.test(item[2]!);
      while (lists.length > 0 && lists[lists.length - 1]!.indent > indent) closeLists(lists.length - 1);
      const top = lists[lists.length - 1];
      if (!top || indent > top.indent) {
        // A nested list opens *inside* the item above it, which is where the
        // parent's still-open `<li>` puts it.
        out.push(ordered ? "<ol>" : "<ul>");
        lists.push({ ordered, indent, itemOpen: false });
      } else if (top.ordered !== ordered) {
        closeLists(lists.length - 1);
        out.push(ordered ? "<ol>" : "<ul>");
        lists.push({ ordered, indent, itemOpen: false });
      }
      const level = lists[lists.length - 1]!;
      if (level.itemOpen) out.push("</li>");
      out.push(`<li>${inline(item[3]!)}`);
      level.itemOpen = true;
      blank = false;
      continue;
    }

    const quoted = line.match(/^\s*>\s?(.*)$/);
    if (quoted) {
      flushPara();
      closeLists(0);
      quote.push(quoted[1]!);
      blank = false;
      continue;
    }

    if (line.trim() === "") {
      flushPara();
      flushQuote();
      blank = true;
      continue;
    }

    // Indented text under an open bullet belongs to that bullet.
    if (lists.length > 0 && /^\s/.test(line)) {
      out.push(` ${inline(line.trim())}`);
      blank = false;
      continue;
    }

    closeLists(0);
    flushQuote();
    if (blank) flushPara();
    para.push(line.trim());
    blank = false;
  }

  // Whatever was mid-flight when the last chunk landed, rendered as what it
  // is so far. The next chunk re-renders the whole reply anyway.
  flushFence();
  flushAll();
  return out.join("");
}

/**
 * The spans inside one line.
 *
 * Code spans come out first and go back last, so a `**` inside backticks is
 * never read as emphasis — the bug you only notice when an agent quotes a
 * glob or a C pointer.
 */
function inline(text: string): string {
  const code: string[] = [];
  // NUL-delimited rather than spelled out of ordinary characters: an agent
  // quoting its own output eventually writes whatever token we picked, and
  // the collision swaps somebody's prose for somebody else's code span.
  let s = escapeHtml(text).replace(/`([^`]+)`/g, (_m, body: string) => `\u0000${code.push(`<code>${body}</code>`) - 1}\u0000`);

  s = s.replace(/\[([^\]]*)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
  // A bare URL, which is how a machine cites things. The trailing-punctuation
  // class keeps the full stop at the end of a sentence out of the href.
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<>()]*[^\s<>().,;:!?])/g, '$1<a href="$2" target="_blank" rel="noreferrer">$2</a>');
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[\s([])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
  s = s.replace(/~~([^~]+)~~/g, "<del>$1</del>");

  return s.replace(/\u0000(\d+)\u0000/g, (_m, i: string) => code[Number(i)]!);
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

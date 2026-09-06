import { describe, expect, test } from "bun:test";
import { renderMarkdown } from "./md";

/**
 * The renderer runs on every chunk of a live reply, over bytes that came off
 * somebody's repository. So the two things worth pinning are what it does
 * with half a construct and what it does with markup it did not write.
 */

describe("renderMarkdown", () => {
  test("paragraphs, emphasis and code spans", () => {
    expect(renderMarkdown("A **bold** and `code` line.")).toBe("<p>A <strong>bold</strong> and <code>code</code> line.</p>");
  });

  test("a code span is not read as emphasis", () => {
    // `**` inside backticks is a glob, not bold — the bug the placeholder pass exists for.
    expect(renderMarkdown("run `ls **/*.ts` now")).toBe("<p>run <code>ls **/*.ts</code> now</p>");
  });

  test("headings, lists and fences", () => {
    const html = renderMarkdown("# Title\n\n- one\n- two\n\n```ts\nconst x = 1;\n```");
    expect(html).toBe('<h1>Title</h1><ul><li>one</li><li>two</li></ul><div class="code-block"><div class="code-block-toolbar"><button type="button" class="code-copy" aria-label="Copy code" aria-live="polite">Copy</button></div><pre><code class="lang-ts">const x = 1;</code></pre></div>');
  });

  test("a blank line between items keeps one list", () => {
    // Closing on the blank would restart <ol> numbering at 1 on every item,
    // which is how an agent writes a numbered plan.
    const html = renderMarkdown("1. first\n\n2. second");
    expect(html).toBe("<ol><li>first</li><li>second</li></ol>");
  });

  test("indented bullets nest inside the item above", () => {
    expect(renderMarkdown("- one\n  - deep\n- two")).toBe("<ul><li>one<ul><li>deep</li></ul></li><li>two</li></ul>");
  });

  test("an unterminated fence renders what has arrived", () => {
    // Every chunk of a live reply ends mid-construct; swallowing the rest of
    // the turn until the closing fence lands is the visible failure.
    expect(renderMarkdown("```\nhalf a f")).toContain("<pre><code>half a f</code></pre>");
  });

  test("html in the reply is text, not markup", () => {
    expect(renderMarkdown('<img src=x onerror="alert(1)">')).toBe("<p>&lt;img src=x onerror=&quot;alert(1)&quot;&gt;</p>");
  });

  test("only http(s) links become links", () => {
    expect(renderMarkdown("[x](javascript:alert(1))")).toBe("<p>[x](javascript:alert(1))</p>");
    expect(renderMarkdown("see https://example.com/a.")).toBe(
      '<p>see <a href="https://example.com/a" target="_blank" rel="noreferrer">https://example.com/a</a>.</p>',
    );
  });

  test("blockquotes and rules", () => {
    expect(renderMarkdown("> quoted\n\n---")).toBe("<blockquote><p>quoted</p></blockquote><hr />");
  });

  test("every tag it opens, it closes", () => {
    const html = renderMarkdown("# H\n\n- a\n  - b\n\n> q\n\n```\ncode\n");
    const opened = html.match(/<(\w+)[^>]*>/g) ?? [];
    const closed = html.match(/<\/(\w+)>/g) ?? [];
    // <hr /> is the only void element this renderer emits, and it is absent here.
    expect(opened.length).toBe(closed.length);
  });
});

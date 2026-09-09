defmodule RavixWeb.MarkdownTest do
  @moduledoc """
  A port of `src/lib/md.test.ts`.

  The renderer runs on every chunk of a live reply, over bytes that came off
  somebody's repository. So the two things worth pinning are what it does
  with half a construct and what it does with markup it did not write.
  """
  use ExUnit.Case, async: true

  import RavixWeb.Markdown, only: [render: 1]

  test "paragraphs, emphasis and code spans" do
    assert render("A **bold** and `code` line.") ==
             "<p>A <strong>bold</strong> and <code>code</code> line.</p>"
  end

  test "a code span is not read as emphasis" do
    # `**` inside backticks is a glob, not bold: the bug the placeholder pass
    # exists for.
    assert render("run `ls **/*.ts` now") == "<p>run <code>ls **/*.ts</code> now</p>"
  end

  test "headings, lists and fences" do
    html = render("# Title\n\n- one\n- two\n\n```ts\nconst x = 1;\n```")

    assert html ==
             ~s(<h1>Title</h1><ul><li>one</li><li>two</li></ul>) <>
               ~s(<div class="code-block"><div class="code-block-toolbar">) <>
               ~s(<button type="button" class="code-copy" aria-label="Copy code" aria-live="polite">Copy</button>) <>
               ~s(</div><pre><code class="lang-ts">const x = 1;</code></pre></div>)
  end

  test "a blank line between items keeps one list" do
    # Closing on the blank would restart <ol> numbering at 1 on every item,
    # which is how an agent writes a numbered plan.
    assert render("1. first\n\n2. second") == "<ol><li>first</li><li>second</li></ol>"
  end

  test "indented bullets nest inside the item above" do
    assert render("- one\n  - deep\n- two") ==
             "<ul><li>one<ul><li>deep</li></ul></li><li>two</li></ul>"
  end

  test "a change of list kind at one level closes and reopens" do
    assert render("- one\n1. two") == "<ul><li>one</li></ul><ol><li>two</li></ol>"
  end

  test "indented text under a bullet belongs to it" do
    assert render("- one\n  continued") == "<ul><li>one continued</li></ul>"
  end

  test "an unterminated fence renders what has arrived" do
    # Every chunk of a live reply ends mid-construct; swallowing the rest of
    # the turn until the closing fence lands is the visible failure.
    assert render("```\nhalf a f") =~ "<pre><code>half a f</code></pre>"
  end

  test "html in the reply is text, not markup" do
    assert render(~s(<img src=x onerror="alert\(1\)">)) ==
             "<p>&lt;img src=x onerror=&quot;alert(1)&quot;&gt;</p>"
  end

  test "html inside a fence and its language are escaped too" do
    assert render("```c++\n<script>\n```") =~ ~s(<code class="lang-c++">&lt;script&gt;</code>)
    assert render("```\na > b\n```") =~ "<pre><code>a &gt; b</code></pre>"
  end

  test "only http(s) links become links" do
    assert render("[x](javascript:alert(1))") == "<p>[x](javascript:alert(1))</p>"

    assert render("see https://example.com/a.") ==
             ~s(<p>see <a href="https://example.com/a" target="_blank" rel="noreferrer">https://example.com/a</a>.</p>)

    assert render("[docs](https://example.com/d)") ==
             ~s(<p><a href="https://example.com/d" target="_blank" rel="noreferrer">docs</a></p>)
  end

  test "emphasis, strikethrough and a half-arrived pair" do
    assert render("a *word* and ~~gone~~") == "<p>a <em>word</em> and <del>gone</del></p>"
    assert render("partial **bo") == "<p>partial **bo</p>"
  end

  test "blockquotes and rules" do
    assert render("> quoted\n\n---") == "<blockquote><p>quoted</p></blockquote><hr />"
  end

  test "paragraphs join their lines and a blank line splits them" do
    assert render("one\ntwo\n\nthree") == "<p>one two</p><p>three</p>"
  end

  test "windows line endings are the same reply" do
    assert render("# H\r\n\r\ntext") == "<h1>H</h1><p>text</p>"
  end

  test "every tag it opens, it closes" do
    html = render("# H\n\n- a\n  - b\n\n> q\n\n```\ncode\n")
    opened = Regex.scan(~r/<(\w+)[^>]*>/, html)
    closed = Regex.scan(~r/<\/(\w+)>/, html)
    # <hr /> is the only void element this renderer emits, and it is absent here.
    assert length(opened) == length(closed)
  end

  test "render_safe is raw html for a template" do
    assert {:safe, "<p>hi</p>"} = RavixWeb.Markdown.render_safe("hi")
  end
end

defmodule RavixWeb.Markdown do
  @moduledoc """
  Markdown, as an agent actually writes it, and while it is still writing.

  A coding agent's reply is markdown (headings, bullets, fenced code, a path
  in backticks) and rendering it as pre-wrapped text throws all of that away.
  What is left reads as a wall of text with stray asterisks in it, which is
  the whole of the difference between "the machine is working" and "some
  generic chat app is echoing something".

  This is a port of the SPA's `src/lib/md.ts`, line for line, rather than a
  call into `Managoat.Docs.Markdown`: that renderer is CommonMark through
  comrak and does sanitise, but its output is not this output. It makes a
  blank line between two bullets a loose list of paragraphs, it unwraps a
  `javascript:` link to its text where this leaves the source visible, and
  it has no copy button on a fence. The transcript's stylesheet and its
  tests were written against this shape, and a renderer that is small
  enough to write is cheaper to keep in step than one that is imported.
  Two things a live transcript needs:

    Streaming. Every call gets the reply so far, so the last construct on
    the page is nearly always half-arrived. An unterminated fence renders as
    an open code block rather than swallowing the rest of the turn, a blank
    line does not close a list that is about to continue, and a partial
    `**bo` renders as its own literal text and becomes bold when the closing
    pair lands.

    Safety. Escape first, always. The bytes here came off a machine running
    somebody's repository, and the only markup in the output is markup this
    module put there. Links are rewritten only for `http(s)`, so no
    `javascript:` target can be spelled.
  """

  @typedoc "A list level: whether it is ordered, the indent that opened it, and whether an `<li>` is open."
  @type level :: %{ordered: boolean(), indent: non_neg_integer(), item_open: boolean()}

  @typep state :: %{
           out: [String.t()],
           lists: [level()],
           para: [String.t()],
           quote: [String.t()],
           fence: nil | %{lang: String.t(), lines: [String.t()]},
           blank: boolean()
         }

  @doc """
  Render markdown to HTML that is safe to pass through `Phoenix.HTML.raw/1`.

  Every byte of the input is escaped before any markup is added, and the
  result is always a well-formed sequence of the tags this module opens.
  """
  @spec render(String.t()) :: String.t()
  def render(src) when is_binary(src) do
    lines = src |> String.replace("\r\n", "\n") |> String.split("\n")

    state = %{out: [], lists: [], para: [], quote: [], fence: nil, blank: false}

    lines
    |> Enum.reduce(state, &line/2)
    # Whatever was mid-flight when the last chunk landed, rendered as what
    # it is so far. The next chunk re-renders the whole reply anyway.
    |> flush_fence()
    |> flush_all()
    |> Map.fetch!(:out)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @doc """
  `render/1`, wrapped as safe HTML for a template.
  """
  @spec render_safe(String.t()) :: Phoenix.HTML.safe()
  # render/1 escapes input before adding markup; malicious HTML/link tests cover it.
  # sobelow_skip ["XSS.Raw"]
  def render_safe(src), do: Phoenix.HTML.raw(render(src))

  # --- one line at a time ---------------------------------------------------

  @spec line(String.t(), state()) :: state()
  defp line(line, %{fence: fence} = state) when not is_nil(fence) do
    if Regex.match?(~r/^\s*```/, line),
      do: flush_fence(state),
      else: %{state | fence: %{fence | lines: [line | fence.lines]}}
  end

  # The block openers: a fence, a heading, a rule, a bullet. Anything else
  # is prose of one kind or another, which `prose/2` sorts out.
  defp line(line, state) do
    cond do
      opening = Regex.run(~r/^\s*```\s*([\w+#.-]+)?/, line) ->
        lang = Enum.at(opening, 1) || ""
        %{flush_all(state) | fence: %{lang: lang, lines: []}, blank: false}

      heading = Regex.run(~r/^(\#{1,4})\s+(.*)$/, line) ->
        [_, hashes, text] = heading
        level = String.length(hashes)

        state
        |> flush_all()
        |> emit("<h#{level}>#{inline(text)}</h#{level}>")
        |> Map.put(:blank, false)

      Regex.match?(~r/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/, line) ->
        state |> flush_all() |> emit("<hr />") |> Map.put(:blank, false)

      item = Regex.run(~r/^(\s*)([-*+]|\d+[.)])\s+(.*)$/, line) ->
        [_, indent, marker, text] = item
        list_item(state, String.length(indent), not Regex.match?(~r/^[-*+]$/, marker), text)

      true ->
        prose(line, state)
    end
  end

  # A quote line, a blank, a continuation of the bullet above, or a line of
  # a paragraph.
  @spec prose(String.t(), state()) :: state()
  defp prose(line, state) do
    cond do
      quoted = Regex.run(~r/^\s*>\s?(.*)$/, line) ->
        [_, text] = quoted

        state
        |> flush_para()
        |> close_lists(0)
        |> Map.update!(:quote, &[text | &1])
        |> Map.put(:blank, false)

      String.trim(line) == "" ->
        state |> flush_para() |> flush_quote() |> Map.put(:blank, true)

      # Indented text under an open bullet belongs to that bullet.
      state.lists != [] and Regex.match?(~r/^\s/, line) ->
        state |> emit(" " <> inline(String.trim(line))) |> Map.put(:blank, false)

      true ->
        state = state |> close_lists(0) |> flush_quote()
        state = if state.blank, do: flush_para(state), else: state
        %{state | para: [String.trim(line) | state.para], blank: false}
    end
  end

  # A bullet. A nested list opens inside the item above it, which is where
  # the parent's still-open `<li>` puts it; a shallower one closes back down
  # to its level; a change of kind at the same level closes and reopens.
  @spec list_item(state(), non_neg_integer(), boolean(), String.t()) :: state()
  defp list_item(state, indent, ordered, text) do
    state =
      state
      |> flush_para()
      |> flush_quote()
      |> close_deeper_than(indent)

    state =
      case state.lists do
        [top | _] when indent <= top.indent and top.ordered == ordered ->
          state

        [top | _] when indent <= top.indent ->
          state
          |> close_lists(length(state.lists) - 1)
          |> open_list(ordered, indent)

        _ ->
          open_list(state, ordered, indent)
      end

    [level | rest] = state.lists
    state = if level.item_open, do: emit(state, "</li>"), else: state

    state
    |> emit("<li>#{inline(text)}")
    |> Map.put(:lists, [%{level | item_open: true} | rest])
    |> Map.put(:blank, false)
  end

  defp close_deeper_than(%{lists: [top | _]} = state, indent) when top.indent > indent do
    state |> close_lists(length(state.lists) - 1) |> close_deeper_than(indent)
  end

  defp close_deeper_than(state, _indent), do: state

  defp open_list(state, ordered, indent) do
    state
    |> emit(if(ordered, do: "<ol>", else: "<ul>"))
    |> Map.update!(:lists, &[%{ordered: ordered, indent: indent, item_open: false} | &1])
  end

  # --- flushing what is open ------------------------------------------------

  defp emit(state, html), do: %{state | out: [html | state.out]}

  defp flush_para(%{para: []} = state), do: state

  defp flush_para(state) do
    text = state.para |> Enum.reverse() |> Enum.join(" ")
    %{emit(state, "<p>#{inline(text)}</p>") | para: []}
  end

  defp flush_quote(%{quote: []} = state), do: state

  defp flush_quote(state) do
    text = state.quote |> Enum.reverse() |> Enum.join(" ")
    %{emit(state, "<blockquote><p>#{inline(text)}</p></blockquote>") | quote: []}
  end

  defp close_lists(state, depth) when length(state.lists) > depth do
    [level | rest] = state.lists
    state = if level.item_open, do: emit(state, "</li>"), else: state

    state
    |> emit(if(level.ordered, do: "</ol>", else: "</ul>"))
    |> Map.put(:lists, rest)
    |> close_lists(depth)
  end

  defp close_lists(state, _depth), do: state

  defp flush_fence(%{fence: nil} = state), do: state

  defp flush_fence(%{fence: fence} = state) do
    cls = if fence.lang == "", do: "", else: ~s( class="lang-#{escape(fence.lang)}")
    code = fence.lines |> Enum.reverse() |> Enum.join("\n") |> escape()

    html =
      ~s(<div class="code-block"><div class="code-block-toolbar">) <>
        ~s(<button type="button" class="code-copy" aria-label="Copy code" aria-live="polite">Copy</button>) <>
        ~s(</div><pre><code#{cls}>#{code}</code></pre></div>)

    %{emit(state, html) | fence: nil}
  end

  defp flush_all(state) do
    state |> flush_para() |> flush_quote() |> close_lists(0)
  end

  # --- the spans inside one line -------------------------------------------

  # Code spans come out first and go back last, so a `**` inside backticks is
  # never read as emphasis, the bug you only notice when an agent quotes a
  # glob or a C pointer. NUL-delimited rather than spelled out of ordinary
  # characters: an agent quoting its own output eventually writes whatever
  # token we picked, and the collision swaps somebody's prose for somebody
  # else's code span.
  @spec inline(String.t()) :: String.t()
  defp inline(text) do
    {s, code} = text |> escape() |> pull_code()

    s =
      s
      |> String.replace(
        ~r/\[([^\]]*)\]\((https?:\/\/[^)\s]+)\)/,
        ~s(<a href="\\2" target="_blank" rel="noreferrer">\\1</a>)
      )
      # A bare URL, which is how a machine cites things. The trailing
      # punctuation class keeps the full stop at the end of a sentence out
      # of the href.
      |> String.replace(
        ~r/(^|[\s(])(https?:\/\/[^\s<>()]*[^\s<>().,;:!?])/,
        ~s(\\1<a href="\\2" target="_blank" rel="noreferrer">\\2</a>)
      )
      |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
      |> String.replace(~r/(^|[\s(\[])\*([^*\s][^*]*)\*/, "\\1<em>\\2</em>")
      |> String.replace(~r/~~([^~]+)~~/, "<del>\\1</del>")

    Regex.replace(~r/\x00(\d+)\x00/, s, fn _, i ->
      Enum.at(code, String.to_integer(i))
    end)
  end

  # Replace each code span with a NUL-framed index into a list of rendered
  # spans, in order of appearance.
  defp pull_code(escaped) do
    {s, code, _} =
      Regex.split(~r/`[^`]+`/, escaped, include_captures: true)
      |> Enum.reduce({[], [], 0}, fn part, {parts, code, n} ->
        case part do
          "`" <> _ ->
            body = String.slice(part, 1..-2//1)
            {["\x00#{n}\x00" | parts], ["<code>#{body}</code>" | code], n + 1}

          _ ->
            {[part | parts], code, n}
        end
      end)

    {s |> Enum.reverse() |> IO.iodata_to_binary(), Enum.reverse(code)}
  end

  @spec escape(String.t()) :: String.t()
  defp escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

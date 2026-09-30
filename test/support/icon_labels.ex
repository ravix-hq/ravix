defmodule RavixWeb.IconLabels do
  @moduledoc """
  The icon-only control check (RAV-98).

  A button or link whose content is only an icon has no name unless it
  carries one, and shows a pointer user nothing about what it does unless it
  has a tooltip. This reads every HEEx template under `lib/` (`.heex` files,
  and `~H` sigils in `.ex` files) and reports each icon-only `<button>`,
  `<a>`, `<.link>`, `<.button>` or `<summary>` that has no accessible name
  (`aria-label`, `aria-labelledby` or visually hidden text) or no
  `data-tip`, the app's one tooltip (`assets/js/tooltip.js`).
  `<.icon_button>` carries both and is not a control this looks for.

  "Icon-only" means that once comments, tags, `aria-hidden` and visually
  hidden (`sr-only`) elements are gone, no word and no `{expression}` is
  left; a glyph such as × or ⋯ is not a word. An expression, or a function
  component other than an icon (`@icons`), is taken to draw words, since a
  template cannot say what it prints.

  `test/ravix_web/icon_labels_test.exs` runs it over the real templates and
  proves it rejects and accepts.
  """

  @controls ~w(button a .link .button summary)
  # The function components that draw no words.
  @icons ~w(.icon .disclosure_chevron .status_dot)

  @hidden ~r/<([.\w-]+)\b[^>]*?\saria-hidden(?:=(?:"true"|\{true\}))?[\s\/>]/
  @sr_only ~r/<([.\w-]+)\b[^>]*?\sclass="(?:[^"]*\s)?sr-only(?:\s[^"]*)?"[\s\/>]/

  @type source :: %{
          path: String.t(),
          source: String.t(),
          offset: non_neg_integer(),
          file: String.t()
        }

  @doc "Every problem under `root`'s `lib/`, as `path:line: message`."
  @spec check(Path.t()) :: [String.t()]
  def check(root \\ ".") do
    root |> templates() |> Enum.flat_map(&check_source(&1, root))
  end

  @doc "Every template source under `root`'s `lib/`."
  @spec templates(Path.t()) :: [source()]
  def templates(root) do
    heex =
      for path <- Path.wildcard(Path.join(root, "lib/**/*.heex")) do
        text = File.read!(path)
        %{path: path, source: text, offset: 0, file: text}
      end

    sigils =
      Enum.flat_map(Path.wildcard(Path.join(root, "lib/**/*.ex")), fn path ->
        sigils(path, File.read!(path))
      end)

    Enum.sort_by(heex ++ sigils, &{&1.path, &1.offset})
  end

  @doc "The bodies of a file's `~H\"\"\"` heredocs, each with its offset in the file."
  @spec sigils(String.t(), String.t()) :: [source()]
  def sigils(path, text) do
    ~r/~H"""\n/
    |> Regex.scan(text, return: :index)
    |> Enum.flat_map(fn [{at, length}] ->
      start = at + length

      case :binary.match(text, ~s("""), scope: {start, byte_size(text) - start}) do
        {finish, _} ->
          [%{path: path, source: slice(text, start, finish), offset: start, file: text}]

        :nomatch ->
          []
      end
    end)
  end

  @doc "The problems in one template source."
  @spec check_source(source(), Path.t()) :: [String.t()]
  def check_source(%{path: path, source: source} = template, root \\ ".") do
    names = Enum.map_join(@controls, "|", &Regex.escape/1)

    ~r/<(#{names})(?=[\s>\/])/
    |> Regex.scan(source, return: :index)
    |> Enum.flat_map(fn [{at, _}, {n, length}] ->
      name = binary_part(source, n, length)

      with {finish, closed?} <- opening_tag(source, at),
           {:ok, content} <- content(source, name, finish, closed?),
           true <- icon_only?(content),
           [_ | _] = missing <- missing(slice(source, at, finish), content) do
        line = line(template, at)
        rel = Path.relative_to(Path.expand(path), Path.expand(root))

        [
          "#{rel}:#{line}: icon-only <#{name}> needs #{Enum.join(missing, " and ")} (or use <.icon_button>)"
        ]
      else
        _ -> []
      end
    end)
  end

  @doc "Whether a control's content has no word a sighted person can read."
  @spec icon_only?(String.t()) :: boolean()
  def icon_only?(content), do: not words?(visible_text(content, true))

  @doc """
  The text of `content` once comments, `aria-hidden` elements and tags are
  gone; `visual` also drops visually hidden (`sr-only`) text. A function
  component other than an icon is left as `{component}`.
  """
  @spec visible_text(String.t(), boolean()) :: String.t()
  def visible_text(content, visual \\ false) do
    text =
      content
      |> String.replace(~r/<%!--.*?--%>/s, "")
      |> String.replace(~r/<!--.*?-->/s, "")
      |> without(@hidden)

    text = if visual, do: without(text, @sr_only), else: text
    text |> strip_tags(0, []) |> String.trim()
  end

  defp missing(attrs, content) do
    named? =
      attribute?(attrs, "aria-label") or attribute?(attrs, "aria-labelledby") or
        words?(visible_text(content))

    Enum.reject(
      [
        !named? && "an aria-label",
        !attribute?(attrs, "data-tip") && "a data-tip tooltip"
      ],
      &(&1 == false)
    )
  end

  defp content(_source, _name, _finish, true), do: {:ok, ""}

  defp content(source, name, finish, false) do
    case closing_tag(source, name, finish) do
      nil -> :error
      close -> {:ok, slice(source, finish, close)}
    end
  end

  defp words?(text) do
    text |> String.replace(~r/&[a-z]+;|&#\w+;/, "") |> String.match?(~r/[\p{L}\p{N}{]/u)
  end

  defp attribute?(tag, name), do: Regex.match?(~r/\s#{Regex.escape(name)}(?=[\s=\/>])/, tag)

  defp line(%{file: file, offset: offset}, at) do
    file |> binary_part(0, offset + at) |> :binary.matches("\n") |> length() |> Kernel.+(1)
  end

  # Where the opening tag starting at `start` ends (the byte after its `>`),
  # skipping quoted values and `{...}` expressions, and whether it closes itself.
  defp opening_tag(source, start), do: scan_tag(source, start + 1, 0, false)

  defp scan_tag(source, i, _depth, _quote?) when i >= byte_size(source), do: nil

  defp scan_tag(source, i, depth, true) do
    case :binary.at(source, i) do
      ?" ->
        if :binary.at(source, i - 1) == ?\\,
          do: scan_tag(source, i + 1, depth, true),
          else: scan_tag(source, i + 1, depth, false)

      _ ->
        scan_tag(source, i + 1, depth, true)
    end
  end

  defp scan_tag(source, i, depth, false) do
    case :binary.at(source, i) do
      ?" -> scan_tag(source, i + 1, depth, true)
      ?{ -> scan_tag(source, i + 1, depth + 1, false)
      ?} -> scan_tag(source, i + 1, depth - 1, false)
      ?> when depth == 0 -> {i + 1, :binary.at(source, i - 1) == ?/}
      _ -> scan_tag(source, i + 1, depth, false)
    end
  end

  # The byte at which the `</name>` closing the element whose content starts
  # at `from` begins.
  defp closing_tag(source, name, from) do
    ~r/<(\/?)#{Regex.escape(name)}(?=[\s>\/])/
    |> Regex.scan(source, return: :index, offset: from)
    |> Enum.reduce_while(1, fn [{at, _}, {_, closing}], depth ->
      cond do
        closing == 1 and depth == 1 -> {:halt, {:at, at}}
        closing == 1 -> {:cont, depth - 1}
        match?({_, false}, opening_tag(source, at)) -> {:cont, depth + 1}
        true -> {:cont, depth}
      end
    end)
    |> case do
      {:at, at} -> at
      _ -> nil
    end
  end

  # `text` without the elements whose opening tag `pattern` matches.
  defp without(text, pattern) do
    with [{at, _}, {n, length}] <- Regex.run(pattern, text, return: :index),
         {finish, closed?} <- opening_tag(text, at),
         {:ok, stop} <- element_end(text, binary_part(text, n, length), finish, closed?) do
      without(slice(text, 0, at) <> slice(text, stop, byte_size(text)), pattern)
    else
      _ -> text
    end
  end

  defp element_end(_text, _name, finish, true), do: {:ok, finish}

  defp element_end(text, name, finish, false) do
    case closing_tag(text, name, finish) do
      nil ->
        :error

      close ->
        {gt, _} = :binary.match(text, ">", scope: {close, byte_size(text) - close})
        {:ok, gt + 1}
    end
  end

  # Tags go whole, so a `>` in one of their expressions cannot end one.
  defp strip_tags(text, i, acc) when i >= byte_size(text),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_tags(text, i, acc) do
    with ?< <- :binary.at(text, i),
         true <- i + 1 < byte_size(text) and tag_start?(:binary.at(text, i + 1)),
         {finish, _} <- opening_tag(text, i) do
      tag = slice(text, i, finish)

      acc =
        case Regex.run(~r/^<(\.[\w.]+)/, tag) do
          [_, component] when component not in @icons -> ["{component}" | acc]
          _ -> acc
        end

      strip_tags(text, finish, acc)
    else
      _ -> strip_tags(text, i + 1, [binary_part(text, i, 1) | acc])
    end
  end

  defp tag_start?(c), do: c in [?., ?/, ?:, ?!, ?_] or c in ?a..?z or c in ?A..?Z or c in ?0..?9

  defp slice(text, from, to), do: binary_part(text, from, to - from)
end

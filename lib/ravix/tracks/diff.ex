defmodule Ravix.Tracks.Diff do
  @moduledoc """
  A unified diff, counted per file.

  Done here rather than in the page because the Changes panel wants the file
  list before it renders anything, and re-deriving it on every keystroke in
  a filter box is work that has one right answer and no reason to be
  repeated.
  """

  defmodule Change do
    @moduledoc """
    One file of a diff, with what happened to it and how much.

    `Change` rather than `File`, which is what it is: a module named `File`
    nested here would shadow `Elixir.File` for every line in this file.
    """

    @enforce_keys [:path, :added, :removed, :status]
    defstruct @enforce_keys

    @type status :: :added | :modified | :deleted | :renamed

    @type t :: %__MODULE__{
            path: String.t(),
            added: non_neg_integer(),
            removed: non_neg_integer(),
            status: status()
          }
  end

  # `files` is enforced like the rest: a `Diff` built without it renders as
  # "0 changed files" beside a non-empty `diff`, indistinguishable from a
  # real empty one.
  @enforce_keys [:path, :repo_root, :diff, :truncated, :changes, :files]
  defstruct @enforce_keys

  @typedoc """
  A track's working diff. `diff` is the unified text as `git` produced it and
  `changes` is that text summarised; `truncated` says Fountain stopped early,
  in which case both are short by the same amount.
  """
  @type t :: %__MODULE__{
          path: String.t() | nil,
          repo_root: String.t() | nil,
          diff: String.t(),
          truncated: boolean(),
          changes: [Change.t()],
          files: [map()]
        }

  @hunk ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/

  @doc "Parse Git sections once, retaining hunk coordinates and metadata."
  @spec parse(String.t(), boolean()) :: [map()]
  def parse(diff, truncated \\ false) do
    sections = Regex.split(~r/^diff --git /m, diff) |> Enum.drop(1)

    last_index = length(sections) - 1

    sections
    |> Enum.map(&section/1)
    |> Enum.with_index()
    |> Enum.map(fn {file, index} ->
      %{file | partial: truncated and index == last_index}
    end)
  end

  @doc "Every file in `diff`, in order, with its counts and what happened to it."
  @spec summarize(String.t()) :: [Change.t()]
  def summarize(diff), do: Enum.map(parse(diff), & &1.change)

  defp section(section) do
    [header | lines] = String.split(section, "\n")
    [from, to] = header_paths(header)

    file = %{
      change: %Change{
        path: to,
        added: 0,
        removed: 0,
        status: if(from == to, do: :modified, else: :renamed)
      },
      old_path: from,
      hunks: [],
      metadata: [],
      binary: false,
      partial: false
    }

    file = Enum.reduce(lines, file, &parse_line/2)

    %{
      file
      | hunks: Enum.map(Enum.reverse(file.hunks), &%{&1 | lines: Enum.reverse(&1.lines)}),
        metadata: Enum.reverse(file.metadata)
    }
  end

  defp header_paths(header) do
    case Regex.run(~r/^("(?:[^"\\]|\\.)*"|a\/.*?) ("(?:[^"\\]|\\.)*"|b\/.*)$/, header) do
      [_, from, to] -> Enum.map([from, to], &(decode_path(&1) |> String.slice(2..-1//1)))
      nil -> [header, header]
    end
  end

  defp decode_path("\"" <> _ = path) do
    path
    |> String.slice(1..-2//1)
    |> then(&Regex.replace(~r/\\([0-7]{3}|.)/s, &1, fn _, escape -> unescape(escape) end))
    # Octal escapes are raw bytes, and git quotes a name precisely when those
    # bytes may not be UTF-8. An invalid binary cannot be sent to the page.
    |> String.replace_invalid()
  end

  defp decode_path(path), do: path
  defp unescape("t"), do: "\t"
  defp unescape("n"), do: "\n"
  defp unescape("r"), do: "\r"

  defp unescape(<<a, b, c>>) when a in ?0..?7 and b in ?0..?7 and c in ?0..?7,
    do: <<String.to_integer(<<a, b, c>>, 8)>>

  defp unescape(other), do: other

  defp parse_line("@@ " <> _ = line, file) do
    case Regex.run(@hunk, line) do
      [_, old, old_count, new, new_count, _] ->
        hunk = %{
          header: line,
          old_start: String.to_integer(old),
          new_start: String.to_integer(new),
          old_count: count(old_count),
          new_count: count(new_count),
          next_old: String.to_integer(old),
          next_new: String.to_integer(new),
          lines: []
        }

        %{file | hunks: [hunk | file.hunks]}

      nil ->
        file
    end
  end

  defp parse_line(line, %{hunks: [hunk | rest]} = file) do
    case line do
      <<prefix, text::binary>> when prefix in [?+, ?-, ?\s] ->
        content_line(file, hunk, rest, prefix, text)

      "\\ No newline at end of file" ->
        %{
          file
          | hunks: [
              %{hunk | lines: List.update_at(hunk.lines, 0, &%{&1 | no_newline: true})} | rest
            ]
        }

      _ ->
        file
    end
  end

  defp parse_line("--- a/" <> path, file),
    do: %{file | old_path: String.trim_trailing(path, "\t")}

  defp parse_line("+++ b/" <> path, file),
    do: %{file | change: %{file.change | path: String.trim_trailing(path, "\t")}}

  defp parse_line("new file mode " <> _ = line, file),
    do: metadata(%{file | change: %{file.change | status: :added}}, line)

  defp parse_line("deleted file mode " <> _ = line, file),
    do: metadata(%{file | change: %{file.change | status: :deleted}}, line)

  defp parse_line("rename from " <> path, file), do: %{file | old_path: decode_path(path)}

  defp parse_line("rename to " <> path, file),
    do: %{file | change: %{file.change | status: :renamed, path: decode_path(path)}}

  defp parse_line("Binary files " <> _, file), do: %{file | binary: true}
  defp parse_line("GIT binary patch", file), do: %{file | binary: true}
  defp parse_line("old mode " <> _ = line, file), do: metadata(file, line)
  defp parse_line("new mode " <> _ = line, file), do: metadata(file, line)
  defp parse_line("similarity index " <> _ = line, file), do: metadata(file, line)
  defp parse_line(_, file), do: file

  defp content_line(file, hunk, rest, prefix, text) do
    old = hunk.next_old
    new = hunk.next_new
    kind = %{?+ => :add, ?- => :del, ?\s => :context}[prefix]

    row = %{
      kind: kind,
      text: text,
      old: if(kind != :add, do: old),
      new: if(kind != :del, do: new),
      no_newline: false
    }

    change = file.change

    change = %{
      change
      | added: change.added + if(kind == :add, do: 1, else: 0),
        removed: change.removed + if(kind == :del, do: 1, else: 0)
    }

    %{
      file
      | change: change,
        hunks: [
          %{
            hunk
            | lines: [row | hunk.lines],
              next_old: old + if(kind != :add, do: 1, else: 0),
              next_new: new + if(kind != :del, do: 1, else: 0)
          }
          | rest
        ]
    }
  end

  defp metadata(file, line), do: %{file | metadata: [line | file.metadata]}
  defp count(""), do: 1
  defp count(value), do: String.to_integer(value)
end

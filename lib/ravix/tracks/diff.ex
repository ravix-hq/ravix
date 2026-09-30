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

    @typedoc "`:untracked` is a new file Git has not been told about; see `with_untracked/2`."
    @type status :: :added | :modified | :deleted | :renamed | :untracked

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

  # The machine's side of `with_untracked/2`: at most this many files, each
  # shown whole up to the size, the lot up to the total, all within the
  # deadline. A file over the size is listed with no lines rather than left out.
  @untracked_files 200
  @untracked_file_bytes 256_000
  @untracked_total_bytes 1_000_000
  @untracked_budget_sec 4

  @external_resource Path.expand("../../../priv/scripts/untracked_diff.py", __DIR__)
  @untracked_script @external_resource |> File.read!() |> Base.encode64()

  @doc """
  A read-only command that prints the worktree's untracked files, as Git
  would diff them against nothing, in JSON. The worktree is encoded, never
  shell syntax. `git diff` leaves them out, which is Fountain's diff.
  """
  @spec untracked_command(String.t()) :: String.t()
  def untracked_command(root) do
    payload =
      Jason.encode!([
        root,
        @untracked_files,
        @untracked_file_bytes,
        @untracked_total_bytes,
        @untracked_budget_sec
      ])
      |> Base.encode64()

    ~s|python3 -c 'import base64;exec(base64.b64decode("#{@untracked_script}"))' #{payload}|
  end

  @doc "How long `untracked_command/1` may take on the machine, in seconds, with room to answer."
  @spec untracked_timeout_sec() :: pos_integer()
  def untracked_timeout_sec, do: @untracked_budget_sec + 2

  @doc """
  `diff` with the untracked files `untracked_command/1` found, as `:untracked`
  changes after the tracked ones. Anything else it was answered with, an
  exec that failed or a machine without Python, leaves `diff` as it was:
  the tracked diff is still true without them.
  """
  @spec with_untracked(t(), term()) :: t()
  def with_untracked(%__MODULE__{} = diff, {:ok, %{code: 0, stdout: output}}) do
    case Jason.decode(output) do
      {:ok, %{"available" => true, "diff" => text, "large" => large, "truncated" => cut}}
      when is_binary(text) and text != "" and is_list(large) ->
        known = MapSet.new(diff.files, & &1.change.path)

        files =
          text
          |> parse()
          |> Enum.reject(&MapSet.member?(known, &1.change.path))
          |> Enum.map(fn file ->
            %{
              file
              | change: %{file.change | status: :untracked},
                partial: file.change.path in large
            }
          end)

        %{
          diff
          | diff: if(diff.diff == "", do: text, else: diff.diff <> "\n" <> text),
            truncated: diff.truncated or cut == true,
            changes: diff.changes ++ Enum.map(files, & &1.change),
            files: diff.files ++ files
        }

      {:ok, %{"available" => true, "truncated" => true}} ->
        %{diff | truncated: true}

      _ ->
        diff
    end
  end

  def with_untracked(%__MODULE__{} = diff, _result), do: diff

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

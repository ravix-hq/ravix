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

  @enforce_keys [:path, :repo_root, :diff, :truncated, :changes]
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
          changes: [Change.t()]
        }

  @header ~r/^diff --git a\/(.+?) b\/(.+)$/

  @doc "Every file in `diff`, in order, with its counts and what happened to it."
  @spec summarize(String.t()) :: [Change.t()]
  def summarize(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce([], &line/2)
    |> Enum.reverse()
  end

  defp line(line, files) do
    case Regex.run(@header, line) do
      [_, from, to] ->
        [
          %Change{
            path: to,
            added: 0,
            removed: 0,
            status: if(from == to, do: :modified, else: :renamed)
          }
          | files
        ]

      nil ->
        count(line, files)
    end
  end

  # Nothing before the first header is a file.
  defp count(_line, []), do: []

  defp count(line, [%Change{} = current | rest]) do
    cond do
      String.starts_with?(line, "new file") -> [%Change{current | status: :added} | rest]
      String.starts_with?(line, "deleted file") -> [%Change{current | status: :deleted} | rest]
      # `+++`/`---` are the file headers, not content, and counting them would
      # put a phantom line on every changed file.
      String.starts_with?(line, "+++") or String.starts_with?(line, "---") -> [current | rest]
      String.starts_with?(line, "+") -> [%Change{current | added: current.added + 1} | rest]
      String.starts_with?(line, "-") -> [%Change{current | removed: current.removed + 1} | rest]
      true -> [current | rest]
    end
  end
end

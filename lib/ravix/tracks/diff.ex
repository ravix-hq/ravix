defmodule Ravix.Tracks.Diff do
  @moduledoc """
  A unified diff, counted per file.

  Done here rather than in the page because the Changes panel wants the file
  list before it renders anything, and re-deriving it on every keystroke in
  a filter box is work that has one right answer and no reason to be
  repeated.
  """

  @typedoc "One file of a diff, the `DiffFile` of `shared/api.ts`."
  @type file :: %{
          path: String.t(),
          added: non_neg_integer(),
          removed: non_neg_integer(),
          status: :added | :modified | :deleted | :renamed
        }

  @header ~r/^diff --git a\/(.+?) b\/(.+)$/

  @doc "Every file in `diff`, in order, with its counts and what happened to it."
  @spec summarize(String.t()) :: [file()]
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
          %{path: to, added: 0, removed: 0, status: if(from == to, do: :modified, else: :renamed)}
          | files
        ]

      nil ->
        count(line, files)
    end
  end

  # Nothing before the first header is a file.
  defp count(_line, []), do: []

  defp count(line, [current | rest]) do
    cond do
      String.starts_with?(line, "new file") -> [%{current | status: :added} | rest]
      String.starts_with?(line, "deleted file") -> [%{current | status: :deleted} | rest]
      # `+++`/`---` are the file headers, not content, and counting them would
      # put a phantom line on every changed file.
      String.starts_with?(line, "+++") or String.starts_with?(line, "---") -> [current | rest]
      String.starts_with?(line, "+") -> [%{current | added: current.added + 1} | rest]
      String.starts_with?(line, "-") -> [%{current | removed: current.removed + 1} | rest]
      true -> [current | rest]
    end
  end
end

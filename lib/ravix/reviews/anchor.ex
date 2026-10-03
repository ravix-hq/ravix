defmodule Ravix.Reviews.Anchor do
  @moduledoc """
  Content-addressed working diff revisions, including untracked/truncation state.
  A revision is a SHA256 fingerprint, not a Git commit: working changes may have
  no commit. Any change marks prior discussions outdated; no fuzzy relocation.
  Only coordinates actually returned by the existing parser can be anchored.
  Binary files and metadata-only changes support file discussions, never lines.
  """
  alias Ravix.Tracks.Diff

  @spec revision(Diff.t()) :: String.t()
  def revision(%Diff{} = diff) do
    :crypto.hash(:sha256, :erlang.term_to_binary({diff.diff, diff.truncated, diff.untracked}))
    |> Base.encode16(case: :lower)
  end

  @spec locate(Diff.t(), map()) :: {:ok, map()} | {:error, tuple()}
  def locate(%Diff{} = diff, attrs) when is_map(attrs) do
    if attrs["revision"] == revision(diff) do
      locate_file(diff, attrs)
    else
      {:error,
       {:conflict, "stale_review", "Changes moved. Refresh before starting a discussion."}}
    end
  end

  def locate(_, _), do: invalid()

  defp locate_file(diff, attrs) do
    case Enum.find(diff.files, &(&1.change.path == attrs["path"])) do
      nil -> invalid()
      file -> coordinate(file, attrs)
    end
  end

  defp coordinate(file, %{"side" => "file"} = attrs) do
    if attrs["line"] in [nil, ""],
      do: {:ok, %{path: file.change.path, side: "file", line: nil, excerpt: nil}},
      else: invalid()
  end

  defp coordinate(%{binary: false} = file, %{"side" => side, "line" => value})
       when side in ["old", "new"] do
    number = number(value)
    key = if side == "old", do: :old, else: :new
    line = Enum.find(Enum.flat_map(file.hunks, & &1.lines), &(number && &1[key] == number))

    if line,
      do: {:ok, %{path: file.change.path, side: side, line: number, excerpt: line.text}},
      else: invalid()
  end

  defp coordinate(_, _), do: invalid()

  defp number(value) when is_integer(value) and value > 0, do: value

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp invalid,
    do:
      {:error, {:unprocessable, "review_anchor", "Choose a file or a visible old/new diff line."}}
end

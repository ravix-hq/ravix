defmodule Ravix.Reviews.Anchor do
  @moduledoc """
  Content-addressed file diff revisions, independent of retrieval availability.
  Raw Git sections retain blob indexes (including binary identities), metadata
  and hunk coordinates. Extra untracked files do not change tracked anchors.
  Partial files and binaries without blob indexes are unverifiable: they may
  retain existing discussions but cannot honestly accept a new revision anchor.
  """
  alias Ravix.Tracks.Diff

  @type status :: :current | :outdated | :unverifiable | :unchecked

  @spec revisions(Diff.t()) :: %{String.t() => String.t() | nil}
  def revisions(%Diff{} = diff) do
    sections =
      Regex.split(~r/^diff --git /m, diff.diff)
      |> Enum.drop(1)
      |> Enum.reduce(%{}, fn section, acc ->
        raw = "diff --git " <> String.trim_trailing(section, "\n")
        [file] = Diff.parse(raw)
        Map.put_new(acc, file.change.path, raw)
      end)

    Map.new(diff.files, fn file ->
      raw = Map.get(sections, file.change.path)
      {file.change.path, fingerprint(file, raw)}
    end)
  end

  @spec revision(Diff.t(), String.t()) :: String.t() | nil
  def revision(%Diff{} = diff, path), do: Map.get(revisions(diff), path)

  @spec status(map(), map() | nil, Diff.untracked(), boolean()) :: status()
  def status(discussion, revisions, availability, truncated \\ false)
  def status(_discussion, nil, _availability, _truncated), do: :unchecked

  def status(discussion, revisions, availability, truncated) do
    case Map.fetch(revisions, discussion.path) do
      {:ok, revision} when revision == discussion.revision -> :current
      {:ok, nil} -> :unverifiable
      {:ok, _} -> :outdated
      :error when truncated or availability != :listed -> :unverifiable
      :error -> :outdated
    end
  end

  @spec locate(Diff.t(), map()) :: {:ok, map()} | {:error, tuple()}
  def locate(%Diff{} = diff, attrs) when is_map(attrs) do
    case Enum.find(diff.files, &(&1.change.path == attrs["path"])) do
      nil -> if is_binary(attrs["revision"]), do: stale(), else: invalid()
      file -> locate_revision(diff, file, attrs)
    end
  end

  def locate(_, _), do: invalid()

  defp locate_revision(diff, file, attrs) do
    expected = attrs["revision"]

    case revision(diff, file.change.path) do
      nil ->
        {:error,
         {:conflict, "unverifiable_review",
          "This file's complete revision is unavailable. Refresh complete changes before starting a discussion."}}

      revision when revision == expected ->
        coordinate(file, attrs)

      _ ->
        stale()
    end
  end

  defp fingerprint(%{partial: true}, _raw), do: nil
  defp fingerprint(_file, nil), do: nil

  defp fingerprint(file, raw) do
    if file.binary && !Regex.match?(~r/^index [0-9a-f]+\.\.[0-9a-f]+(?: \d+)?$/m, raw),
      do: nil,
      else: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
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

  defp stale,
    do:
      {:error,
       {:conflict, "stale_review", "Changes moved. Refresh before starting a discussion."}}

  defp invalid,
    do:
      {:error, {:unprocessable, "review_anchor", "Choose a file or a visible old/new diff line."}}
end

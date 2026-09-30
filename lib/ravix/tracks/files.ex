defmodule Ravix.Tracks.Files do
  @moduledoc """
  Reading a track's directory, and the one rule about it.

  The Files panel belongs to a track, and a track is one directory. The
  browser says where it wants to look; `confine/2` decides. Without it the
  panel is a way to read every other track's work and, since
  `GET /api/sandboxes/:id/file` will happily serve `/home/sprite/.ssh`,
  rather more than that.

  The two readers are free: Fountain sandbox reads do not wake a parked box.
  Git and symlink metadata is a separate, optional read on a running machine.
  The readers answer `Listing` and `Content` below -- structs
  rather than the bare maps they were, so that the panel holding one can be
  asked *which* it is holding instead of being told by a second assign, and
  so a field renamed here fails where the value is built.
  """

  defmodule Entry do
    @moduledoc "One entry of a directory. Fountain's word for a directory is `\"directory\"`."

    @enforce_keys [:name, :type, :size]
    defstruct @enforce_keys ++ [ignored?: false, target: nil, directory_target: nil]

    @type t :: %__MODULE__{
            name: String.t(),
            type: String.t(),
            size: integer() | nil,
            ignored?: boolean(),
            directory_target: String.t() | nil,
            target: String.t() | nil
          }
  end

  defmodule Listing do
    @moduledoc "A directory, as the Files panel shows it."

    @enforce_keys [:path, :entries, :truncated]
    defstruct @enforce_keys ++ [ignore_available?: false]

    @type t :: %__MODULE__{
            path: String.t(),
            entries: [Entry.t()],
            truncated: boolean(),
            ignore_available?: boolean()
          }
  end

  defmodule Content do
    @moduledoc """
    One file's bytes. `encoding` is `"base64"` for a file that is not text,
    which is the panel's cue to report a size rather than render it.
    """

    @enforce_keys [:path, :size, :truncated, :encoding, :content]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            path: String.t(),
            size: integer(),
            truncated: boolean(),
            encoding: String.t(),
            content: String.t()
          }
  end

  defmodule Index do
    @moduledoc """
    The track's files as paths relative to its worktree, shallowest first:
    what the composer's `@` searches. `truncated` says the walk stopped at
    one of its bounds, so the person can be told a file may be missing.
    """

    @enforce_keys [:paths, :truncated]
    defstruct @enforce_keys

    @type t :: %__MODULE__{paths: [String.t()], truncated: boolean()}
  end

  @index_paths 3_000
  @index_directories 120

  # Directories nobody means when they @-mention a file, and the ones that
  # would spend the whole walk on themselves.
  @index_skip ~w(.git node_modules _build deps .elixir_ls dist build target vendor .venv venv
                 __pycache__ .next .nuxt .cache cover coverage tmp)

  @doc """
  Every file under `root`, breadth first, within bounds.

  `read_many` takes absolute directory paths and answers, in the same order, a
  `Listing` for each or `nil` for one that could not be read. Nothing outside
  `root` is ever asked for: an entry whose name is not a single path segment
  is not followed, a listing that answers for a different directory than the
  one asked is ignored, and every path asked for is checked with `confine/2`.
  The walk reads at most #{@index_directories} directories and keeps at most
  #{@index_paths} paths.
  """
  @spec index(String.t(), ([String.t()] -> [Listing.t() | nil])) :: Index.t()
  def index(root, read_many), do: walk(root, read_many, [""], [], 0, false)

  defp walk(_root, _read_many, [], paths, _reads, truncated),
    do: %Index{paths: Enum.reverse(paths), truncated: truncated}

  defp walk(_root, _read_many, _level, paths, reads, _truncated) when reads >= @index_directories,
    do: %Index{paths: Enum.reverse(paths), truncated: true}

  defp walk(root, read_many, level, paths, reads, truncated) do
    {batch, rest} = Enum.split(level, @index_directories - reads)
    asked = Enum.map(batch, &under(root, &1))
    answers = read_many.(asked)

    {next, paths, truncated} =
      [batch, asked, answers]
      |> Enum.zip()
      |> Enum.reduce({[], paths, truncated or rest != []}, &take_listing/2)

    if length(paths) >= @index_paths,
      do: %Index{paths: paths |> Enum.reverse() |> Enum.take(@index_paths), truncated: true},
      else: walk(root, read_many, Enum.reverse(next), paths, reads + length(batch), truncated)
  end

  defp take_listing({relative, absolute, %Listing{path: path} = listing}, acc)
       when is_binary(path) do
    {next, paths, truncated} = acc

    if String.trim_trailing(path, "/") == absolute do
      listing.entries
      |> Enum.filter(&segment?(&1.name))
      |> Enum.sort_by(& &1.name)
      |> Enum.reduce({next, paths, truncated or listing.truncated}, &take_entry(relative, &1, &2))
    else
      {next, paths, true}
    end
  end

  defp take_listing({_relative, _absolute, _unreadable}, {next, paths, _truncated}),
    do: {next, paths, true}

  defp take_entry(relative, entry, {next, paths, truncated}) do
    child = if relative == "", do: entry.name, else: "#{relative}/#{entry.name}"

    case entry.type do
      "directory" when entry.name in @index_skip -> {next, paths, truncated}
      "directory" -> {[child | next], paths, truncated}
      "file" -> {next, [child | paths], truncated}
      _ -> {next, paths, truncated}
    end
  end

  defp segment?(name) when is_binary(name),
    do: name not in ["", ".", ".."] and not String.contains?(name, ["/", "\\", <<0>>, "\n"])

  defp segment?(_name), do: false

  defp under(root, ""), do: root

  defp under(root, relative) do
    # `relative` is built from checked segments, so this always holds; it is
    # asked anyway because a listing that walks out of the worktree is the
    # one thing this function must never do.
    absolute = "#{root}/#{relative}"
    ^absolute = confine(root, absolute)
  end

  @doc """
  A path, pinned inside the track's own worktree.

  Relative paths resolve under `root`; absolute ones are taken as given; `.`
  and `..` are folded; and anything that ends up outside `root` snaps back to
  `root` rather than raising, because the panel shows where it actually is
  and an escape is not something the person needs a lecture about.
  """
  @spec confine(String.t(), String.t() | nil) :: String.t()
  def confine(root, requested) when requested in [nil, ""], do: root

  def confine(root, requested) when is_binary(requested) do
    absolute = if String.starts_with?(requested, "/"), do: requested, else: "#{root}/#{requested}"

    # `Path.expand/1` on an already-absolute path is pure string work: it
    # resolves `.` and `..`, collapses repeated separators, and stops at the
    # root, which is every case the hand-written reduction here covered. It
    # touches no filesystem, so a `..` that escapes is flattened rather than
    # followed, and the comparison below is what refuses it.
    normalized = Path.expand(absolute, "/")

    if normalized == root or String.starts_with?(normalized, root <> "/"),
      do: normalized,
      else: root
  end

  @doc "A Fountain listing as the page reads it."
  @spec present_listing(map()) :: Listing.t()
  def present_listing(raw) do
    %Listing{
      path: raw["path"],
      truncated: raw["truncated"] == true,
      entries:
        raw["entries"]
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.map(&%Entry{name: &1["name"], type: &1["type"] || "other", size: &1["size"]})
    }
  end

  @external_resource Path.expand("../../../priv/scripts/file_metadata.py", __DIR__)
  @metadata_script @external_resource |> File.read!() |> Base.encode64()

  @doc "A read-only metadata command; all path input is encoded, never shell syntax."
  @spec metadata_command(String.t(), Listing.t()) :: String.t()
  def metadata_command(root, listing) do
    payload =
      Jason.encode!([root, listing.path, Enum.map(listing.entries, & &1.name)]) |> Base.encode64()

    ~s|python3 -c 'import base64;exec(base64.b64decode("#{@metadata_script}"))' #{payload}|
  end

  @doc "Enrich a listing when machine metadata is available; preserve it on failure."
  @spec with_metadata(Listing.t(), term()) :: Listing.t()
  def with_metadata(listing, {:ok, %{code: 0, stdout: output}}) do
    case Jason.decode(output) do
      {:ok, %{"entries" => entries, "ignore_available" => available}} when is_map(entries) ->
        updated =
          Enum.map(listing.entries, fn entry ->
            metadata = Map.get(entries, entry.name, %{})
            target = metadata["target"]

            %{
              entry
              | ignored?: metadata["ignored"] == true,
                target: if(is_binary(target), do: target),
                directory_target:
                  if(is_binary(metadata["directory_target"]), do: metadata["directory_target"]),
                type: if(is_binary(target), do: "symlink", else: entry.type)
            }
          end)

        %{listing | entries: updated, ignore_available?: available == true}

      _ ->
        listing
    end
  end

  def with_metadata(listing, _), do: listing

  @doc "A Fountain file read as the page reads it."
  @spec present_file(map()) :: Content.t()
  def present_file(raw) do
    %Content{
      path: raw["path"],
      size: raw["size"] || 0,
      truncated: raw["truncated"] == true,
      encoding: raw["encoding"] || "utf-8",
      content: raw["content"] || ""
    }
  end
end

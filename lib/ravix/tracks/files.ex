defmodule Ravix.Tracks.Files do
  @moduledoc """
  Reading a track's directory, and the one rule about it.

  The Files panel belongs to a track, and a track is one directory. The
  browser says where it wants to look; `confine/2` decides. Without it the
  panel is a way to read every other track's work and, since
  `GET /api/sandboxes/:id/file` will happily serve `/home/sprite/.ssh`,
  rather more than that.

  The two readers here are free: a Fountain sandbox read does not wake a
  parked box. What they answer are `Listing` and `Content` below -- structs
  rather than the bare maps they were, so that the panel holding one can be
  asked *which* it is holding instead of being told by a second assign, and
  so a field renamed here fails where the value is built.
  """

  defmodule Entry do
    @moduledoc "One entry of a directory. Fountain's word for a directory is `\"directory\"`."

    @enforce_keys [:name, :type, :size]
    defstruct @enforce_keys

    @type t :: %__MODULE__{name: String.t(), type: String.t(), size: integer() | nil}
  end

  defmodule Listing do
    @moduledoc "A directory, as the Files panel shows it."

    @enforce_keys [:path, :entries, :truncated]
    defstruct @enforce_keys

    @type t :: %__MODULE__{path: String.t(), entries: [Entry.t()], truncated: boolean()}
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

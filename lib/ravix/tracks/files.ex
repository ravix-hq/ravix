defmodule Ravix.Tracks.Files do
  @moduledoc """
  Reading a track's directory, and the one rule about it.

  The Files panel belongs to a track, and a track is one directory. The
  browser says where it wants to look; `confine/2` decides. Without it the
  panel is a way to read every other track's work and, since
  `GET /api/sandboxes/:id/file` will happily serve `/home/sprite/.ssh`,
  rather more than that.

  The two readers here are free: a Fountain sandbox read does not wake a
  parked box. The shapes they answer are `FileListing` and `FileContent`
  from `shared/api.ts`, with atom keys.
  """

  @typedoc "One entry of a directory. Fountain's word for a directory is `\"directory\"`."
  @type entry :: %{name: String.t(), type: String.t(), size: integer() | nil}
  @type listing :: %{path: String.t(), entries: [entry()], truncated: boolean()}
  @type content :: %{
          path: String.t(),
          size: integer(),
          truncated: boolean(),
          encoding: String.t(),
          content: String.t()
        }

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

    normalized =
      absolute
      |> String.split("/")
      |> Enum.reduce([], fn
        part, parts when part in ["", "."] -> parts
        "..", [] -> []
        "..", [_ | parts] -> parts
        part, parts -> [part | parts]
      end)
      |> Enum.reverse()
      |> then(&("/" <> Enum.join(&1, "/")))

    if normalized == root or String.starts_with?(normalized, root <> "/"),
      do: normalized,
      else: root
  end

  @doc "A Fountain listing as the page reads it."
  @spec present_listing(map()) :: listing()
  def present_listing(raw) do
    %{
      path: raw["path"],
      truncated: raw["truncated"] == true,
      entries:
        raw["entries"]
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.map(&%{name: &1["name"], type: &1["type"] || "other", size: &1["size"]})
    }
  end

  @doc "A Fountain file read as the page reads it."
  @spec present_file(map()) :: content()
  def present_file(raw) do
    %{
      path: raw["path"],
      size: raw["size"] || 0,
      truncated: raw["truncated"] == true,
      encoding: raw["encoding"] || "utf-8",
      content: raw["content"] || ""
    }
  end
end

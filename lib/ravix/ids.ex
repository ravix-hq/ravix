defmodule Ravix.Ids do
  @moduledoc """
  Names, and the fact that a name here is load-bearing in four places at once.

  A track's slug is its directory on the machine, the tail of its branch, the
  tail of its `channel_id`, and the thing a person reads in the sidebar. One
  function makes it so the four cannot drift, and `parse_channel/1` is the
  inverse: the server derives a track's identity from Fountain's own record
  rather than trusting a row in its database to still be right.

  A port of `shared/ids.ts`, function for function.
  """

  @typedoc "What a track's `channel_id` says about it."
  @type parsed_channel :: %{project_id: String.t(), track_slug: String.t(), rev: integer()}

  @doc "Every conversation ravix owns starts with this."
  @spec channel_prefix() :: String.t()
  def channel_prefix, do: "ravix"

  @doc "Where a project's repositories are cloned. Fountain's convention."
  @spec workspace_root() :: String.t()
  def workspace_root, do: "/workspace"

  @doc "Where a track's worktree lives. One directory per track, under here."
  @spec work_root() :: String.t()
  def work_root, do: "/home/sprite/work"

  @doc "Ravix's corner of the machine: receipts, notes, nothing a person edits."
  @spec state_dir() :: String.t()
  def state_dir, do: "/home/sprite/.ravix"

  @doc """
  A slug fit for a directory, a git branch and a URL at the same time.

  Git refuses a fair amount that a directory would take (`..`, a trailing
  `.lock`, a leading dot), so the strict rule wins for all four uses rather
  than each place having its own idea of what is legal.
  """
  @spec slugify(String.t(), String.t()) :: String.t()
  def slugify(input, fallback \\ "track") do
    base =
      input
      |> String.downcase()
      |> String.normalize(:nfkd)
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.replace(~r/^-+|-+$/, "")
      |> String.replace(~r/-{2,}/, "-")
      |> String.slice(0, 40)
      |> String.replace(~r/-+$/, "")

    if base == "", do: fallback, else: base
  end

  @doc "`ravix:<project>`: the project's own conversations, if it ever has one."
  @spec project_channel(String.t()) :: String.t()
  def project_channel(project_id), do: "#{channel_prefix()}:#{project_id}"

  @doc """
  `ravix:<project>:<track>@r<rev>`: a track's conversation.

  The revision is the project's settings revision at the moment the track
  opened. Fountain injects secrets, MCP servers and skills when a session
  starts, so a track that opened before a change is genuinely running older
  settings; carrying the number in the id it already has means nothing is
  stored to work that out and nothing can get it wrong. Paddock's trick,
  unchanged.
  """
  @spec track_channel(String.t(), String.t(), integer()) :: String.t()
  def track_channel(project_id, track_slug, rev),
    do: "#{channel_prefix()}:#{project_id}:#{track_slug}@r#{rev}"

  @doc "The inverse. Nil for anything that is not one of ours."
  @spec parse_channel(String.t() | nil) :: parsed_channel() | nil
  def parse_channel(nil), do: nil

  def parse_channel(channel_id) when is_binary(channel_id) do
    case Regex.run(~r/^ravix:([^:@]+):([^:@]+)@r(\d+)$/, channel_id) do
      [_, project_id, slug, rev] ->
        %{project_id: project_id, track_slug: slug, rev: String.to_integer(rev)}

      nil ->
        nil
    end
  end

  @doc "Is this conversation part of the given project, whatever its revision?"
  @spec project_channel?(String.t() | nil, String.t()) :: boolean()
  def project_channel?(channel_id, project_id) do
    case parse_channel(channel_id) do
      %{project_id: ^project_id} -> true
      _ -> false
    end
  end

  @doc "A track's working directory: `/home/sprite/work/<slug>`."
  @spec workdir_for(String.t()) :: String.t()
  def workdir_for(slug), do: "#{work_root()}/#{slug}"

  @doc """
  A track's branch.

  Namespaced under the person who asked for it, the way a human would name a
  branch they intend to push: `jhgaylor/kyoto-<track-id>`. The login comes
  from GitHub, so it is the same name that will appear on the pull request.
  Names can outlive the local branch and even the project database on GitHub.
  """
  @spec branch_for(String.t(), String.t(), String.t()) :: String.t()
  def branch_for(login, slug, track_id), do: "#{slugify(login, "sy")}/#{slug}-#{track_id}"

  @doc "`/workspace/<name>` for `owner/name`."
  @spec mount_path_for(String.t()) :: String.t()
  def mount_path_for(repo_full_name) do
    name = repo_full_name |> String.split("/") |> List.last() || repo_full_name
    "#{workspace_root()}/#{name}"
  end
end

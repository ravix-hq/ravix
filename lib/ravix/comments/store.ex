defmodule Ravix.Comments.Store do
  @moduledoc "Row access behind `Ravix.Comments`' thread access door. Takes ids and asks nobody."
  import Ecto.Query

  alias Ravix.Accounts.User
  alias Ravix.Comments.{Comment, Mention}
  alias Ravix.Repo

  def get(id) when is_binary(id), do: Repo.get(Comment, id) |> Repo.preload(:author)
  def get(_), do: nil

  @doc "A thread's comments, oldest first, deleted ones included, authors loaded."
  def list(thread_id) do
    Repo.all(
      from c in Comment,
        where: c.thread_id == ^thread_id,
        order_by: [asc: c.inserted_at, asc: c.id],
        preload: :author
    )
  end

  def insert(changeset) do
    with {:ok, comment} <- Repo.insert(changeset), do: {:ok, Repo.preload(comment, :author)}
  end

  def update(changeset) do
    with {:ok, comment} <- Repo.update(changeset), do: {:ok, Repo.preload(comment, :author)}
  end

  @doc "Name these people on a comment. Somebody already named keeps their first mention."
  def mention(_comment_id, [], _at), do: 0

  def mention(comment_id, user_ids, at) do
    rows = Enum.map(user_ids, &%{comment_id: comment_id, user_id: &1, inserted_at: at})
    {count, _} = Repo.insert_all(Mention, rows, on_conflict: :nothing)
    count
  end

  @doc "Who a comment named."
  def mentioned(comment_id),
    do: Repo.all(from m in Mention, where: m.comment_id == ^comment_id, select: m.user_id)

  @doc """
  Everyone who might reach a track: the project's owner and members, the
  track's members, its creator and -- with `RAVIX_WORKSPACE_ACCESS` on --
  its workspace's members and permission holders. A superset; each is still put through
  `Ravix.Accounts.Access.track_access/2` before being offered or notified.
  """
  def candidates(track, project) do
    # ownership: Comments went through Access.thread_access for this track; these
    # are the membership rows that door itself reads, asked for the list at once.
    members =
      Repo.all(
        from m in Ravix.Projects.ProjectMember,
          where: m.project_id == ^project.id,
          select: m.user_id
      )

    # ownership: as above, Access.thread_access admitted the caller to this track.
    named =
      Repo.all(
        from m in Ravix.Tracks.TrackMember, where: m.track_id == ^track.id, select: m.user_id
      )

    # ownership: as above; `Access.workspace_audience/2` is empty with the switch off.
    audience = Ravix.Accounts.Access.workspace_audience(project.id, [track.id])
    workspace = Enum.map(audience.members ++ Map.get(audience.permitted, track.id, []), & &1.id)

    ids =
      Enum.uniq(
        Enum.reject(
          [project.user_id, track.created_by | members ++ named ++ workspace],
          &is_nil/1
        )
      )

    # ownership: Access.thread_access as above; each is put through the door again.
    Repo.all(from u in User, where: u.id in ^ids, order_by: [asc: u.login])
  end

  @doc """
  For each thread, when somebody other than `user_id` last commented on it,
  and the newest comment that named `user_id`. Deleted comments count for
  neither. Keyed by thread id, each `%{comment_at:, mention:}`; a thread
  with neither is absent.
  """
  def activity(_user_id, []), do: %{}

  def activity(user_id, thread_ids) do
    latest =
      Repo.all(
        from c in Comment,
          where: c.thread_id in ^thread_ids and c.author_id != ^user_id and is_nil(c.deleted_at),
          group_by: c.thread_id,
          select: {c.thread_id, max(c.inserted_at)}
      )

    # ownership: callers admitted these threads through Access.open_tracks or
    # Access.thread_access; the author's login is the one fact read from
    # Accounts, for the Inbox line.
    mentions =
      Repo.all(
        from m in Mention,
          join: c in Comment,
          on: c.id == m.comment_id,
          join: a in User,
          on: a.id == c.author_id,
          where: m.user_id == ^user_id and c.thread_id in ^thread_ids and is_nil(c.deleted_at),
          distinct: c.thread_id,
          order_by: [asc: c.thread_id, desc: m.inserted_at],
          select: {c.thread_id, %{comment_id: c.id, author_login: a.login, at: m.inserted_at}}
      )

    by_thread = Map.new(latest, fn {id, at} -> {id, %{comment_at: at, mention: nil}} end)

    Enum.reduce(mentions, by_thread, fn {id, mention}, acc ->
      Map.update(acc, id, %{comment_at: nil, mention: mention}, &%{&1 | mention: mention})
    end)
  end
end

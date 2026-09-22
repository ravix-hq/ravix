defmodule Ravix.Tracks.Store do
  @moduledoc """
  The track rows, with nobody's permission established.

  These carried an `_unsafe_` prefix while they lived at the bottom of
  `Ravix.Tracks`, which is the same idea as this module and a weaker version
  of it: a prefix is a promise every future caller has to keep reading, and
  `Ravix.Credo.Architecture` could only ever check it on remote calls, of
  which there were none. Every call was local, inside the one file, so the
  rule that was meant to police this had never once fired.

  A module name is checkable. `Ravix.Tracks` establishes access through
  `Ravix.Accounts.Access` and then calls in here; anybody else has to write
  `Tracks.Store.` and say in a `# ownership:` comment which door they went
  through, and nothing in `lib/ravix_web/` may write it at all.
  """

  import Ecto.Query

  alias Ravix.Repo
  alias Ravix.Tracks.{Thread, ThreadRead, Track, TrackMember}

  @doc "A track row. The caller brings the id decided in the opening plan."
  @spec create_track(map()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def create_track(attrs), do: %Track{} |> Track.changeset(attrs) |> Repo.insert()

  @doc "A thread on this track; nil selects its stable default."
  def thread(track_id, thread_id \\ nil)

  def thread(track_id, thread_id)
      when is_binary(track_id) and (is_binary(thread_id) or is_nil(thread_id)),
      do: Repo.get_by(Thread, id: thread_id || track_id, track_id: track_id)

  def thread(_track_id, _thread_id), do: nil

  def get_thread(id), do: Repo.get(Thread, id)

  def threads_of(track_id),
    do:
      Repo.all(
        from(t in Thread,
          where: t.track_id == ^track_id,
          order_by: [asc: t.created_at, asc: t.id]
        )
      )

  def threads_by_track(track_ids) do
    Repo.all(
      from(t in Thread,
        where: t.track_id in ^track_ids,
        order_by: [asc: t.created_at, asc: t.id]
      )
    )
    |> Enum.group_by(& &1.track_id)
  end

  def create_thread(attrs) do
    changeset = Thread.changeset(%Thread{}, attrs)

    if changeset.valid?,
      do: Repo.transaction(fn -> insert_thread_locked(changeset) end),
      else: {:error, changeset}
  end

  defp insert_thread_locked(changeset) do
    track_id = Ecto.Changeset.get_field(changeset, :track_id)

    with %Track{closed_at: nil} <-
           Repo.one(from(t in Track, where: t.id == ^track_id, lock: "FOR UPDATE")),
         {:ok, thread} <- Repo.insert(changeset) do
      thread
    else
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:not_found)
    end
  end

  def mark_thread_read(thread_id, user_id, at) do
    Repo.insert!(%ThreadRead{thread_id: thread_id, user_id: user_id, seen_at: at},
      on_conflict: {:replace, [:seen_at]},
      conflict_target: [:thread_id, :user_id]
    )

    :ok
  end

  def thread_reads(user_id, project_id) do
    Repo.all(
      from(r in ThreadRead,
        join: th in Thread,
        on: th.id == r.thread_id,
        join: t in Track,
        on: t.id == th.track_id,
        where: r.user_id == ^user_id and t.project_id == ^project_id,
        select: {r.thread_id, r.seen_at}
      )
    )
    |> Map.new()
  end

  @doc "One track by id, closed or not."
  @spec get_track(String.t()) :: Track.t() | nil
  def get_track(id) when is_binary(id), do: Repo.get(Track, id)
  def get_track(_id), do: nil

  @doc "The track a conversation belongs to."
  @spec track_by_conversation(String.t()) :: Track.t() | nil
  def track_by_conversation(conversation_id) when is_binary(conversation_id),
    do:
      Repo.one(
        from(t in Track,
          join: th in Thread,
          on: th.track_id == t.id,
          where: th.conversation_id == ^conversation_id
        )
      )

  def track_by_conversation(_), do: nil

  @typedoc "The open tracks of a project, or every one it ever had."
  @type scope :: :open | :all

  @doc "A project's tracks, oldest first."
  @spec tracks_of(String.t(), scope()) :: [Track.t()]
  def tracks_of(project_id, scope \\ :open) when scope in [:open, :all] do
    query = from(t in Track, where: t.project_id == ^project_id, order_by: t.created_at)
    query = if scope == :all, do: query, else: where(query, [t], is_nil(t.closed_at))
    Repo.all(query)
  end

  @doc "The open tracks of one project this person was named on, oldest first."
  @spec member_tracks_of(String.t(), String.t()) :: [Track.t()]
  # ownership: no door before this one. `track_members` is the people
  # context's table, joined here because the question is about tracks: which
  # of this project's tracks may this person see, which is what
  # `Ravix.Tracks.list/2` decides with it. `Ravix.People.Store` answers the
  # mirror of it.
  def member_tracks_of(user_id, project_id) do
    Repo.all(
      from(t in Track,
        join: m in TrackMember,
        on: m.track_id == t.id,
        where: m.user_id == ^user_id and t.project_id == ^project_id and is_nil(t.closed_at),
        order_by: t.created_at
      )
    )
  end

  @doc "Whether a slug is free right now: the unique index enforces it, this explains it."
  @spec slug_taken?(String.t(), String.t()) :: boolean()
  def slug_taken?(project_id, slug) do
    Repo.exists?(
      from(t in Track,
        where: t.project_id == ^project_id and t.slug == ^slug and is_nil(t.closed_at)
      )
    )
  end

  @doc "Give a track its conversation, in the instant between the two."
  @spec attach_conversation(String.t(), String.t(), String.t() | nil) :: :ok
  def attach_conversation(track_id, conversation_id, thread_id \\ nil) do
    if is_nil(thread_id) or thread_id == track_id do
      update_track(track_id, conversation_id: conversation_id)
    else
      Repo.update_all(from(t in Thread, where: t.id == ^thread_id and t.track_id == ^track_id),
        set: [conversation_id: conversation_id]
      )

      :ok
    end
  end

  @doc "The opening turn reported back. Idempotent: the first time stands."
  @spec mark_opened(String.t()) :: :ok
  def mark_opened(track_id) do
    Repo.update_all(from(t in Track, where: t.id == ^track_id and is_nil(t.opened_at)),
      set: [opened_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc "Rename the label, and only the label."
  @spec rename_track(String.t(), String.t()) :: :ok
  def rename_track(track_id, title), do: update_track(track_id, title: title)

  @doc "Close the row. Waiting prompts are cancelled by the caller through `Ravix.PromptQueue.Store.cancel_track/1`."
  @spec close_track(String.t()) :: :ok
  def close_track(track_id) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Repo.update_all(from(t in Track, where: t.id == ^track_id and is_nil(t.closed_at)),
          set: [closed_at: DateTime.utc_now()]
        )

        Repo.update_all(from(t in Thread, where: t.track_id == ^track_id and is_nil(t.closed_at)),
          set: [closed_at: DateTime.utc_now()]
        )

        :ok
      end)

    :ok
  end

  defp update_track(track_id, changes) do
    Repo.update_all(from(t in Track, where: t.id == ^track_id), set: changes)
    :ok
  end
end

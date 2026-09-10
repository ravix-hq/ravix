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
  alias Ravix.Tracks.{Track, TrackMember}

  @doc "A track row. The caller brings the id, since the branch name carries it."
  @spec create_track(map()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def create_track(attrs), do: %Track{} |> Track.changeset(attrs) |> Repo.insert()

  @doc "One track by id, closed or not."
  @spec get_track(String.t()) :: Track.t() | nil
  def get_track(id) when is_binary(id), do: Repo.get(Track, id)
  def get_track(_id), do: nil

  @doc "The track a conversation belongs to."
  @spec track_by_conversation(String.t()) :: Track.t() | nil
  def track_by_conversation(conversation_id) when is_binary(conversation_id),
    do: Repo.get_by(Track, conversation_id: conversation_id)

  def track_by_conversation(_), do: nil

  @doc "A project's tracks, oldest first: the open ones, or every one it ever had."
  @spec tracks_of(String.t(), boolean()) :: [Track.t()]
  def tracks_of(project_id, include_closed? \\ false) do
    query = from(t in Track, where: t.project_id == ^project_id, order_by: t.created_at)
    query = if include_closed?, do: query, else: where(query, [t], is_nil(t.closed_at))
    Repo.all(query)
  end

  @doc "The open tracks of one project this person was named on, oldest first."
  @spec member_tracks_of(String.t(), String.t()) :: [Track.t()]
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
  @spec attach_conversation(String.t(), String.t()) :: :ok
  def attach_conversation(track_id, conversation_id) do
    update_track(track_id, conversation_id: conversation_id)
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

  @doc "Close the row. Waiting prompts are cancelled by the caller through `Ravix.PromptQueue.cancel_track/1`."
  @spec close_track(String.t()) :: :ok
  def close_track(track_id) do
    Repo.update_all(from(t in Track, where: t.id == ^track_id and is_nil(t.closed_at)),
      set: [closed_at: DateTime.utc_now()]
    )

    :ok
  end

  defp update_track(track_id, changes) do
    Repo.update_all(from(t in Track, where: t.id == ^track_id), set: changes)
    :ok
  end
end

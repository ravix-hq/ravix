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
  alias Ravix.Tracks.{Thread, ThreadRead, Track}

  # The caller has scoped thread access, or holds the durable setup lease.
  def record_turn_failure(conversation_id, turn_id, stage, failure) do
    %Ravix.Tracks.TurnFailure{
      conversation_id: conversation_id,
      turn_id: turn_id,
      stage: stage,
      code: failure.code,
      reason: failure.reason
    }
    |> Ravix.Repo.insert!(on_conflict: :nothing)
  end

  def set_visibility(track, visibility) do
    track |> Track.changeset(%{visibility: visibility}) |> Repo.update()
  end

  def transcript_runtime(%Thread{runtime: runtime}) when is_binary(runtime), do: runtime

  def transcript_runtime(%Thread{track_id: id}) do
    # ownership: no door; reads runtime for an authorized follower or an explicit operator backfill.
    Repo.one(
      from t in Track,
        join: p in Ravix.Projects.Project,
        on: p.id == t.project_id,
        where: t.id == ^id,
        select: p.runtime
    )
  end

  @doc "Corrections and completion markers for the authorized thread's conversations."
  def turn_classifications(conversation_ids) do
    rows =
      Repo.all(
        from f in Ravix.Tracks.TurnFailure,
          where: f.conversation_id in ^conversation_ids and f.stage in ["turn", "classification"]
      )

    failures =
      rows
      |> Enum.filter(&(&1.stage == "turn" and &1.state == "failed"))
      |> Map.new(&{&1.turn_id, %{code: &1.code, reason: &1.reason}})

    %{failures: failures, classified: MapSet.new(rows, &{&1.conversation_id, &1.turn_id})}
  end

  def turn_failure(conversation_id, turn_id),
    do:
      Repo.get_by(Ravix.Tracks.TurnFailure,
        conversation_id: conversation_id,
        turn_id: turn_id,
        stage: "turn"
      )

  @doc "Serialize settlement across followers/restarts, including successful classifications."
  def classify_turn_once(conversation_id, turn_id, fun) do
    Repo.transaction(fn ->
      lock = conversation_id <> ":" <> turn_id
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock])
      key = [conversation_id: conversation_id, turn_id: turn_id, stage: "classification"]

      unless Repo.get_by(Ravix.Tracks.TurnFailure, key),
        do: classify_locked(key, fun)
    end)
  end

  defp classify_locked(key, fun) do
    existing = Repo.get_by(Ravix.Tracks.TurnFailure, Keyword.put(key, :stage, "turn"))
    result = if existing, do: {:ok, nil}, else: fun.()

    case result do
      {:ok, failure} ->
        if failure, do: record_turn_failure(key[:conversation_id], key[:turn_id], "turn", failure)

        Repo.insert!(
          struct!(Ravix.Tracks.TurnFailure, key ++ [state: "completed", code: "", reason: ""])
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  def turn_classified?(conversation_id, turn_id),
    do:
      Repo.exists?(
        from f in Ravix.Tracks.TurnFailure,
          where:
            f.conversation_id == ^conversation_id and f.turn_id == ^turn_id and
              f.stage == "classification"
      )

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

  @doc """
  Insert a thread on an open track. `also`, run inside the same transaction
  with the new row, returns `{:ok, _}` or `{:error, reason}`; an error rolls
  the thread back with it, which is how a thread and its first prompt are
  written together.
  """
  def create_thread(attrs, generation \\ nil, also \\ fn _thread -> {:ok, nil} end) do
    changeset = Thread.changeset(%Thread{}, attrs)

    if changeset.valid?,
      do: Repo.transaction(fn -> insert_thread_locked(changeset, generation, also) end),
      else: {:error, changeset}
  end

  defp insert_thread_locked(changeset, expected_generation, also) do
    track_id = Ecto.Changeset.get_field(changeset, :track_id)

    with %Track{closed_at: nil, sandbox_state: state, sandbox_generation: generation}
         when state not in [:closing, :terminated] <-
           Repo.one(from(t in Track, where: t.id == ^track_id, lock: "FOR UPDATE")),
         true <- is_nil(expected_generation) or generation == expected_generation,
         {:ok, thread} <- Repo.insert(changeset),
         {:ok, _} <- also.(thread) do
      remember_runtime(track_id, thread.runtime)
      thread
    else
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:not_found)
    end
  end

  def create_track(attrs, selection) do
    Repo.transaction(fn ->
      case create_track(Map.put(attrs, :last_runtime, selection.runtime)) do
        {:ok, track} ->
          from(t in Thread, where: t.id == ^track.id)
          |> Repo.update_all(set: [runtime: selection.runtime, model: selection.model])

          track

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def set_thread_model(id, model) do
    from(t in Thread, where: t.id == ^id) |> Repo.update_all(set: [model: model])
    :ok
  end

  defp remember_runtime(_id, nil), do: :ok

  defp remember_runtime(id, runtime) do
    from(t in Track, where: t.id == ^id) |> Repo.update_all(set: [last_runtime: runtime])
    :ok
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

  @doc "Dedicated identities excluded from legacy project-machine discovery."
  def dedicated_identities(project_id) do
    Repo.all(
      from(t in Track,
        left_join: th in Thread,
        on: th.track_id == t.id,
        where: t.project_id == ^project_id and t.sandbox_layout == :dedicated,
        select: {t.sandbox_id, th.conversation_id}
      )
    )
    |> Enum.unzip()
  end

  @doc "One track by id, closed or not."
  @spec get_track(String.t()) :: Track.t() | nil
  def setup_status(id),
    do: Repo.one(from t in Track, where: t.id == ^id, select: map(t, [:setup_state]))

  def get_track(id) when is_binary(id), do: Repo.get(Track, id)
  def get_track(_id), do: nil

  def get_tracks(ids), do: Repo.all(from t in Track, where: t.id in ^ids)

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

  @doc "Persist a rejected source's replacement identity before any provider mutation."
  def recover_credentials(track, thread_id) do
    Repo.transaction(fn ->
      current = Repo.one!(from(t in Track, where: t.id == ^track.id, lock: "FOR UPDATE"))

      thread =
        Repo.one!(
          from(t in Thread,
            where: t.id == ^thread_id and t.track_id == ^track.id,
            lock: "FOR UPDATE"
          )
        )

      if current.closed_at || thread.closed_at ||
           current.sandbox_generation != track.sandbox_generation,
         do: Repo.rollback(:stale_generation)

      if thread.conversation_id == track.conversation_id and is_nil(thread.credential_recovery) do
        recovery = %{
          "channel" => Ecto.UUID.generate(),
          "generation" => current.sandbox_generation,
          "conversation" => thread.conversation_id,
          "attempted" => false
        }

        thread |> Ecto.Changeset.change(credential_recovery: recovery) |> Repo.update!()
      else
        thread
      end
    end)
  end

  def attempt_credential_recovery(thread) do
    recovery = Map.put(thread.credential_recovery, "attempted", true)

    {count, _} =
      Repo.update_all(
        from(t in Thread,
          where: t.id == ^thread.id and t.credential_recovery == ^thread.credential_recovery
        ),
        set: [credential_recovery: recovery]
      )

    if count == 1,
      do: {:ok, %{thread | credential_recovery: recovery}},
      else: {:error, :stale_recovery}
  end

  def retry_credential_recovery(thread) do
    Repo.update_all(
      from(t in Thread,
        where: t.id == ^thread.id and t.credential_recovery == ^thread.credential_recovery
      ),
      set: [credential_recovery: Map.put(thread.credential_recovery, "attempted", false)]
    )

    :ok
  end

  def bind_credential_recovery(track, thread, conversation_id) do
    Repo.transaction(fn ->
      current = Repo.one!(from(t in Track, where: t.id == ^track.id, lock: "FOR UPDATE"))
      fresh = Repo.one!(from(t in Thread, where: t.id == ^thread.id, lock: "FOR UPDATE"))
      recovery = thread.credential_recovery

      if current.closed_at || fresh.closed_at || current.sandbox_state != :ready ||
           current.sandbox_generation != recovery["generation"] ||
           fresh.credential_recovery != recovery,
         do: Repo.rollback(:stale_generation)

      fresh
      |> Ecto.Changeset.change(
        conversation_id: conversation_id,
        credential_recovery: nil,
        recovery_context_pending: true,
        previous_conversation_ids: fresh.previous_conversation_ids ++ [fresh.conversation_id]
      )
      |> Repo.update!()

      if thread.id == track.id, do: update_track(track.id, conversation_id: conversation_id)
      :ok
    end)
  end

  def credential_context_delivered(thread_id, conversation_id) do
    Repo.update_all(
      from(t in Thread, where: t.id == ^thread_id and t.conversation_id == ^conversation_id),
      set: [recovery_context_pending: false]
    )

    :ok
  end

  @doc "Due setup checks, including tracks with no queued prompts or connected page."
  def pending_setups, do: Repo.all(from(t in setup_candidates(), select: t.id))

  @doc """
  When the soonest setup check that is not due yet falls due, or nil.

  `Ravix.Tracks.Setup` spaces its checks from five seconds up to thirty, so
  the queue worker sweeps then rather than on its backstop, which could leave
  a finished opening turn unverified for most of another interval.
  """
  def next_setup_due do
    now = DateTime.utc_now()

    Repo.one(
      from t in open_setups(), where: t.setup_retry_at > ^now, select: min(t.setup_retry_at)
    )
  end

  defp setup_candidates do
    now = DateTime.utc_now()

    from t in open_setups(),
      where:
        (is_nil(t.setup_retry_at) or t.setup_retry_at <= ^now) and
          (is_nil(t.setup_lease_until) or t.setup_lease_until < ^now)
  end

  defp open_setups do
    from t in Track,
      where: is_nil(t.closed_at) and t.setup_state in ["pending", "running", "retry"],
      where:
        t.sandbox_layout == :shared or
          (t.sandbox_state == :provisioning and not is_nil(t.conversation_id))
  end

  @doc "A durable lease shared by initial send, retry and every instance's sweep."
  def claim_setup(id) do
    token = Ecto.UUID.generate()

    {_count, rows} =
      Repo.update_all(
        from(t in setup_candidates(), where: t.id == ^id, select: t),
        set: [setup_lease: token, setup_lease_until: DateTime.add(DateTime.utc_now(), 360)]
      )

    List.first(rows)
  end

  @doc "An expired worker cannot overwrite a newer setup generation."
  def update_setup(track, attrs) do
    {count, _} =
      Repo.update_all(
        from(t in Track,
          where:
            t.id == ^track.id and t.setup_lease == ^track.setup_lease and is_nil(t.closed_at) and
              t.sandbox_generation == ^track.sandbox_generation and
              (t.sandbox_layout == :shared or t.sandbox_state == :provisioning)
        ),
        set: attrs
      )

    count == 1
  end

  @doc "Only an explicit retry resets the exhausted failure budget."
  def retry_setup(id) do
    {count, _} =
      Repo.update_all(
        from(t in Track,
          where: t.id == ^id and is_nil(t.closed_at) and t.setup_state in ["failed", "retry"]
        ),
        set: [
          setup_state: "retry",
          setup_attempts: 0,
          setup_retry_at: DateTime.utc_now(),
          setup_lease: nil,
          setup_lease_until: nil
        ]
      )

    count == 1
  end

  @doc """
  Wake setup parked on a sleeping shared machine now. An explicit request,
  like `retry_setup/1`, but setup has not failed, so its budget stands.
  """
  def wake_setup(id) do
    {count, _} =
      Repo.update_all(
        from(t in Track,
          where:
            t.id == ^id and is_nil(t.closed_at) and t.setup_state == "running" and
              t.setup_error_code == "sandbox_suspended"
        ),
        set: [
          setup_state: "retry",
          setup_retry_at: DateTime.utc_now(),
          setup_lease: nil,
          setup_lease_until: nil
        ]
      )

    count == 1
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

defmodule Ravix.Tracks.Sandbox.Store do
  @moduledoc """
  Unscoped persistence primitives for durable dedicated lifecycle work.
  The caller must establish
  track access before starting intent. No provider effects run here.

  A new intent advances the track generation atomically with its operation.
  Progress on old operations is retained for cleanup but cannot mutate the
  track. Leases fence operation progress; generation checks fence track and
  thread updates. Provider effects belong to the lifecycle worker.
  """
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Ravix.Repo
  alias Ravix.Tracks.{Opening, Track}
  alias Ravix.Tracks.Sandbox.Operation

  @states %{open: :provisioning, close: :closing, rebuild: :provisioning}

  @doc "Advance only the expected dedicated generation and persist intent in the same transaction."
  def begin_operation(track_id, generation, action) when action in [:open, :close, :rebuild] do
    Repo.transaction(fn ->
      track = current_track!(track_id, generation)
      next = generation + 1

      track
      |> Track.changeset(%{sandbox_generation: next, sandbox_state: Map.fetch!(@states, action)})
      |> save!()

      %Operation{}
      |> Operation.changeset(%{
        track_id: track_id,
        generation: next,
        action: action,
        resource_ids: %{"sandbox_id" => track.sandbox_id, "vault_id" => track.vault_id}
      })
      |> save!()
    end)
  end

  @doc "A late provider result cannot replace a newer generation's ownership."
  def update_sandbox(track_id, generation, attrs) do
    Repo.transaction(fn ->
      track = current_track!(track_id, generation)

      track
      |> Track.changeset(Map.take(attrs, [:sandbox_id, :sandbox_state, :vault_id]))
      |> save!()
    end)
  end

  @doc "Historical intent, including pending cleanup from replaced generations."
  def operations(track_id) do
    Repo.all(from(o in Operation, where: o.track_id == ^track_id, order_by: [asc: o.generation]))
  end

  @doc "Progress is revision-fenced, independently of the current track generation."
  def update_operation(%Operation{} = operation, attrs) do
    operation
    |> Operation.progress_changeset(attrs)
    |> Repo.update(stale_error_field: :revision)
  end

  @doc "Persist the row, default thread and open intent atomically, before provider allocation."
  def create(plan, selection, project) do
    Repo.transaction(fn ->
      attrs = Opening.track_attrs(plan, nil)

      attrs =
        Map.merge(attrs, %{
          sandbox_layout: :dedicated,
          setup_state: "pending",
          setup_attempts: 0,
          setup_started_at: nil,
          sandbox_stage: "creating",
          secrets_generation: project.secrets_generation
        })

      track = unwrap!(Ravix.Tracks.Store.create_track(attrs, selection))
      {:ok, op} = begin_operation(track.id, 0, :open)

      resources =
        Map.merge(op.resource_ids, %{
          "agent_id" => selection.agent_id,
          "environment_id" => project.environment_id,
          "source_vault_id" => project.vault_id,
          "runtime" => selection.runtime,
          "model" => selection.model,
          "channel_id" => Ravix.Ids.track_channel(project.id, track.slug, track.rev, track.id)
        })

      {:ok, _} = update_operation(op, %{resource_ids: resources})
      get_track(track.id)
    end)
  end

  @doc "Serialize shared allocation with retirement of the final shared machine."
  def shared_open(project_id, fun) do
    shared_lock(project_id, fn ->
      # ownership: Access.project_access admitted this shared allocation.
      project = Ravix.Projects.Store.live_project(project_id)

      shared_available(project, fun)
    end)
  end

  defp shared_available(nil, _fun), do: {:error, :not_found}

  defp shared_available(%{shared_machine_retiring: true}, _fun),
    do:
      {:error,
       {:conflict, "machine_cleanup_pending",
        "The previous shared machine is being removed. Try opening again shortly."}}

  defp shared_available(_project, fun), do: fun.()

  defp shared_lock(project_id, fun) do
    Repo.checkout(
      fn ->
        SQL.query!(Repo, "SELECT pg_advisory_lock(hashtextextended($1, 7))", [
          project_id
        ])

        try do
          fun.()
        after
          SQL.query!(Repo, "SELECT pg_advisory_unlock(hashtextextended($1, 7))", [
            project_id
          ])
        end
      end,
      timeout: 180_000
    )
  end

  def close_shared(track, project),
    do: shared_lock(project.id, fn -> close_shared_locked(track, project) end)

  defp close_shared_locked(track, project) do
    # ownership: Access.track_access admitted close; the project row fences shared allocation.
    Repo.transaction(fn ->
      # ownership: Access.track_access and require_owner_or_cutter admitted this close.
      Repo.one!(
        from p in Ravix.Projects.Project, where: p.id == ^track.project_id, lock: "FOR UPDATE"
      )

      Ravix.Tracks.Store.close_track(track.id)

      remaining =
        Repo.exists?(
          from t in Track,
            where:
              t.project_id == ^track.project_id and
                t.sandbox_layout == :shared and is_nil(t.closed_at)
        )

      if not remaining do
        row = get_track(track.id)
        Repo.update_all(from(t in Track, where: t.id == ^track.id), inc: [sandbox_generation: 1])

        %Operation{}
        |> Operation.changeset(%{
          track_id: track.id,
          generation: row.sandbox_generation + 1,
          action: :close,
          resource_ids: %{
            "legacy" => true,
            "agent_id" => shared_home_agent(project),
            "environment_id" => project.environment_id,
            "vault_id" => project.vault_id
          }
        })
        |> save!()

        # ownership: no door — the final shared-track close owns project retirement.
        Repo.update_all(from(p in Ravix.Projects.Project, where: p.id == ^track.project_id),
          set: [shared_machine_retiring: true]
        )
      end

      :ok
    end)
  end

  defp shared_home_agent(%{shared_home_runtime: home, runtime: runtime, agent_id: id})
       when is_nil(home) or home == runtime, do: id

  defp shared_home_agent(project) do
    # ownership: Access.track_access admitted closing this project's final shared track.
    project.id
    |> Ravix.Projects.Store.runtime_agents()
    |> Enum.find_value(fn agent ->
      if agent.runtime == project.shared_home_runtime, do: agent.agent_id
    end)
  end

  def finish_shared(op, track) do
    # ownership: no door — the durable final shared-track operation owns the project fence.
    Repo.transaction(fn ->
      {:ok, _} = progress(op, %{phase: "done", completed_at: DateTime.utc_now()})
      # ownership: no door — the final shared-track operation owns the retirement fence.
      Repo.update_all(from(p in Ravix.Projects.Project, where: p.id == ^track.project_id),
        set: [shared_machine_retiring: false, shared_home_runtime: nil]
      )
    end)
  end

  def get_track(id), do: Repo.get(Track, id)
  def get_operation(id), do: Repo.get(Operation, id)

  def context(op) do
    track = get_track(op.track_id)
    # ownership: no door — the durable operation owns this track's resource cleanup.
    {track, Ravix.Projects.Store.live_project(track.project_id)}
  end

  def pending do
    now = DateTime.utc_now()

    Repo.all(
      from o in Operation,
        where:
          is_nil(o.completed_at) and o.phase != "failed" and
            (is_nil(o.retry_at) or o.retry_at <= ^now),
        select: o.id
    )
  end

  def claim(id) do
    now = DateTime.utc_now()
    token = Ecto.UUID.generate()

    {_, rows} =
      Repo.update_all(
        from(o in Operation,
          where:
            o.id == ^id and is_nil(o.completed_at) and
              (is_nil(o.lease_until) or o.lease_until < ^now) and
              (is_nil(o.retry_at) or o.retry_at <= ^now),
          select: o
        ),
        set: [lease: token, lease_until: DateTime.add(now, 360), updated_at: now],
        inc: [attempts: 1, revision: 1]
      )

    List.first(rows)
  end

  @doc "A leased transition records progress and fences updates to the current generation."
  def progress(op, attrs, track_attrs \\ []) do
    Repo.transaction(fn ->
      current = Repo.one(from o in Operation, where: o.id == ^op.id, lock: "FOR UPDATE")
      if current.lease != op.lease, do: Repo.rollback(:lost_lease)
      {:ok, next} = update_operation(current, attrs)

      apply_track_progress(op, track_attrs)

      next
    end)
  end

  defp apply_track_progress(_op, []), do: :ok

  defp apply_track_progress(op, attrs) do
    {count, _} =
      Repo.update_all(
        from(t in Track,
          where: t.id == ^op.track_id and t.sandbox_generation == ^op.generation
        ),
        set: attrs
      )

    if count == 1 and Keyword.has_key?(attrs, :closed_at) do
      Repo.update_all(from(t in Ravix.Tracks.Thread, where: t.track_id == ^op.track_id),
        set: [closed_at: Keyword.fetch!(attrs, :closed_at)]
      )
    end
  end

  def release(op) do
    Repo.update_all(from(o in Operation, where: o.id == ^op.id and o.lease == ^op.lease),
      set: [lease: nil, lease_until: nil]
    )

    :ok
  end

  def request_close(track) do
    Repo.transaction(fn ->
      row = Repo.one!(from t in Track, where: t.id == ^track.id, lock: "FOR UPDATE")

      if row.sandbox_state not in [:closing, :terminated] do
        {:ok, _} = begin_operation(row.id, row.sandbox_generation, :close)

        Repo.update_all(from(t in Track, where: t.id == ^row.id),
          set: [
            sandbox_stage: "closing",
            setup_state: "pending",
            setup_lease: nil,
            setup_lease_until: nil
          ]
        )
      end

      :ok
    end)
  end

  def request_rebuild(track, project) do
    Repo.transaction(fn ->
      row = current_track!(track.id, track.sandbox_generation)
      if row.sandbox_state in [:closing, :terminated], do: Repo.rollback(:closing)
      {:ok, op} = begin_operation(row.id, row.sandbox_generation, :rebuild)

      old =
        Repo.one!(
          from o in Operation,
            where:
              o.track_id == ^row.id and
                o.action in [:open, :rebuild] and o.generation < ^op.generation,
            order_by: [desc: o.generation],
            limit: 1
        )

      resources =
        old.resource_ids
        |> Map.drop(["conversation_id"])
        |> Map.merge(%{
          "sandbox_id" => row.sandbox_id,
          "vault_id" => row.vault_id,
          "source_vault_id" => project.vault_id
        })

      {:ok, _} = update_operation(op, %{phase: "rebuilding", resource_ids: resources})

      Repo.update_all(
        from(t in Ravix.Tracks.Thread,
          where: t.track_id == ^row.id and t.id != ^row.id and is_nil(t.closed_at)
        ),
        set: [closed_at: DateTime.utc_now()]
      )

      Repo.update_all(from(t in Track, where: t.id == ^row.id),
        set: [
          setup_state: "pending",
          sandbox_stage: "creating",
          setup_lease: nil,
          setup_lease_until: nil,
          secrets_generation: project.secrets_generation
        ]
      )
    end)
  end

  def retry(track) do
    Repo.transaction(fn ->
      row = current_track!(track.id, track.sandbox_generation)
      if row.sandbox_state in [:closing, :terminated], do: Repo.rollback(:closing)

      op =
        Repo.one!(
          from o in Operation,
            where: o.track_id == ^row.id and o.generation == ^row.sandbox_generation
        )

      if op.phase != "failed", do: Repo.rollback(:pending)

      {:ok, _} =
        update_operation(op, %{
          phase: "pending",
          retry_at: nil,
          error: nil,
          completed_at: nil,
          resource_ids: Map.drop(op.resource_ids, ["vault_id", "sandbox_id", "conversation_id"])
        })

      row
      |> Track.changeset(%{
        sandbox_state: :provisioning,
        sandbox_stage: "creating",
        setup_state: "pending",
        setup_error: nil,
        setup_error_code: nil
      })
      |> Repo.update!()
    end)
  end

  def prior_pending?(op) do
    Repo.exists?(
      from o in Operation,
        where:
          o.track_id == ^op.track_id and
            o.generation < ^op.generation and is_nil(o.completed_at) and o.phase != "failed"
    )
  end

  def ready(op) do
    progress(op, %{phase: "done", completed_at: DateTime.utc_now(), error: nil},
      sandbox_state: :ready,
      sandbox_stage: "ready"
    )
  end

  def bind(op, conversation_id, sandbox_id) do
    resources =
      Map.merge(op.resource_ids, %{
        "conversation_id" => conversation_id,
        "sandbox_id" => sandbox_id
      })

    progress(op, %{resource_ids: resources, phase: "setup"},
      conversation_id: conversation_id,
      sandbox_id: sandbox_id,
      vault_id: resources["vault_id"],
      setup_state: "running",
      setup_attempts: 1,
      setup_started_at: DateTime.utc_now(),
      setup_retry_at: nil,
      sandbox_stage: "setup"
    )
  end

  defp current_track!(id, generation) do
    case Repo.one(from(t in Track, where: t.id == ^id, lock: "FOR UPDATE")) do
      %Track{sandbox_layout: :dedicated, sandbox_generation: ^generation} = track -> track
      _ -> Repo.rollback(:stale_generation)
    end
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp save!(changeset) do
    case Repo.insert_or_update(changeset) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end

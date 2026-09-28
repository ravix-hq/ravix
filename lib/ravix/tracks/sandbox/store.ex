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
  alias Ravix.Projects.Project
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
      |> Track.changeset(%{
        sandbox_generation: next,
        sandbox_state: Map.fetch!(@states, action),
        sandbox_action: action,
        sandbox_suspended_at: nil
      })
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
  # ownership: Access.project_access admitted this dedicated open before reserving its project.
  def create(plan, selection, project) do
    Repo.transaction(fn ->
      current = Ravix.Projects.Store.lock_retirement(project.id)
      if current.deletion_requested_at || current.archived_at, do: Repo.rollback(:not_found)
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

  @doc "Serialize the opt-in fence check and allocation with last-shared retirement."
  def shared_open(project_id, fun) do
    # ownership: Access.project_access admitted this shared allocation.
    maintenance? =
      Ravix.Config.dedicated_rollout?() and
        case Ravix.Projects.Store.live_project(project_id) do
          nil -> false
          project -> Project.maintenance?(project)
        end

    if Ravix.Config.retire_shared_machines?() or maintenance? do
      Ravix.Cluster.project_mutation(project_id, :shared_machine, fn ->
        # ownership: Access.project_access admitted this shared allocation.
        shared_available(Ravix.Projects.Store.live_project(project_id), fun)
      end)
    else
      fun.()
    end
  end

  defp shared_available(nil, _fun), do: {:error, :not_found}

  defp shared_available(%{shared_machine_retiring: true}, _fun),
    do:
      {:error,
       {:conflict, "machine_cleanup_pending",
        "The previous shared machine is being removed. Try opening again shortly."}}

  defp shared_available(_project, fun), do: fun.()

  def close_shared(track, project) do
    if Ravix.Config.retire_shared_machines?() do
      Ravix.Cluster.project_mutation(project.id, :shared_machine, fn ->
        close_shared_retiring(track, project)
      end)
    else
      Ravix.Tracks.Store.close_track(track.id)
      {:ok, :ok}
    end
  end

  defp close_shared_retiring(track, project) do
    # ownership: Access.track_access and require_owner_or_cutter admitted this retirement.
    Repo.transaction(fn ->
      # ownership: Access.track_access and require_owner_or_cutter admitted this close.
      Ravix.Projects.Store.lock_retirement(track.project_id)
      row = Repo.one!(from t in Track, where: t.id == ^track.id, lock: "FOR UPDATE")
      if row.closed_at, do: Repo.rollback(:already_closed)

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

        # ownership: Access.track_access and require_owner_or_cutter admitted retirement.
        Ravix.Projects.Store.set_retiring(track.project_id, true)
      end

      :ok
    end)
    |> case do
      {:error, :already_closed} -> {:ok, :ok}
      result -> result
    end
  end

  defp shared_home_agent(project) do
    if is_nil(project.shared_home_runtime) or
         project.shared_home_runtime == Project.home_runtime(project) do
      project.agent_id
    else
      # ownership: Access.track_access admitted closing this project's final shared track.
      project.id
      |> Ravix.Projects.Store.runtime_agents()
      |> Enum.find_value(fn agent ->
        if agent.runtime == project.shared_home_runtime, do: agent.agent_id
      end)
    end
  end

  def finish_shared(op, track, error \\ nil) do
    # ownership: the durable close was admitted by Access.track_access and require_owner_or_cutter.
    Repo.transaction(fn ->
      attrs = %{
        phase: if(error, do: "failed", else: "done"),
        completed_at: DateTime.utc_now(),
        error: error
      }

      case progress(op, attrs) do
        {:ok, _} ->
          # ownership: the durable close was admitted by Access.track_access and require_owner_or_cutter.
          Ravix.Projects.Store.finish_retirement(track.project_id, is_nil(error))

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def get_track(id), do: Repo.get(Track, id)
  def get_operation(id), do: Repo.get(Operation, id)

  def context(op) do
    track = get_track(op.track_id)

    # ownership: the durable operation was admitted by Access.track_access and require_owner_or_cutter.
    {track, Ravix.Projects.Store.get_project(track.project_id)}
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

    if count == 1 and Keyword.has_key?(attrs, :conversation_id) do
      Repo.update_all(from(t in Ravix.Tracks.Thread, where: t.id == ^op.track_id),
        set: [credential_recovery: nil, recovery_context_pending: false]
      )
    end

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

  def close_project(project) do
    for track <- Ravix.Tracks.Store.tracks_of(project.id, :all),
        track.sandbox_layout == :dedicated and track.sandbox_state != :terminated do
      # ownership: Access.project_of admitted durable deletion of this project.
      Ravix.PromptQueue.Store.cancel_track(track.id)
      unwrap!(request_close(track))
    end

    unwrap!(retire_shared_tracks(project))
  end

  # ownership: Access.project_of admitted this project’s shared-only rebuild or deletion.
  def retire_shared_tracks(project), do: Repo.transaction(fn -> retire_shared_locked(project) end)

  # ownership: Access.project_of admitted this project’s shared-only rebuild or deletion.
  defp retire_shared_locked(project) do
    # ownership: Access.project_of admitted this shared-only rebuild or deletion.
    Ravix.Projects.Store.lock_retirement(project.id)

    tracks =
      Repo.all(
        from t in Track,
          where:
            t.project_id == ^project.id and t.sandbox_layout == :shared and is_nil(t.closed_at),
          lock: "FOR UPDATE"
      )

    if tracks != [] do
      for track <- tracks do
        Ravix.Tracks.Store.close_track(track.id)
        # ownership: Access.project_of admitted retiring these shared tracks.
        Ravix.PromptQueue.Store.cancel_track(track.id)
      end

      track = List.first(tracks)
      generation = track.sandbox_generation + 1

      Repo.update_all(from(t in Track, where: t.id == ^track.id),
        set: [sandbox_generation: generation]
      )

      %Operation{}
      |> Operation.changeset(%{
        track_id: track.id,
        generation: generation,
        action: :close,
        resource_ids: %{
          "legacy" => true,
          "maintenance" => true,
          "shared_tracks" => Enum.map(tracks, & &1.id),
          "agent_id" => shared_home_agent(project),
          "environment_id" => project.environment_id,
          "vault_id" => project.vault_id
        }
      })
      |> save!()

      # ownership: Access.project_of admitted the retirement fence before provider effects.
      Ravix.Projects.Store.set_retiring(project.id, true)
    end

    :ok
  end

  def shared_retirements(project_id) do
    Repo.all(
      from o in Operation,
        join: t in Track,
        on: t.id == o.track_id,
        where:
          t.project_id == ^project_id and t.sandbox_layout == :shared and is_nil(o.completed_at) and
            o.phase != "failed"
    )
  end

  def project_clean?(id) do
    tracks = from(t in Track, where: t.project_id == ^id, select: t.id)

    not Repo.exists?(
      from t in Track,
        where:
          t.project_id == ^id and t.sandbox_layout == :dedicated and
            t.sandbox_state != :terminated
    ) and
      not Repo.exists?(
        from o in Operation,
          where: o.track_id in subquery(tracks) and is_nil(o.completed_at) and o.phase != "failed"
      )
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

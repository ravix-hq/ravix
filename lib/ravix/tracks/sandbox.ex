defmodule Ravix.Tracks.Sandbox do
  @moduledoc "Durable track machine operations. Callers authorize intent; leases fence each provider step."
  alias Ravix.Fountain
  alias Ravix.Fountain.Error
  alias Ravix.Fountain.Launch
  alias Ravix.Hub
  alias Ravix.MachineCache
  alias Ravix.Previews.Lifecycle
  alias Ravix.Projects.Machine
  alias Ravix.Spec
  alias Ravix.Tracks.Sandbox.Maintenance
  alias Ravix.Tracks.Sandbox.OpenTrace
  alias Ravix.Tracks.Sandbox.Store
  alias Ravix.Tracks.Setup

  def advance(client, id) do
    case Store.claim(id) do
      nil ->
        :ok

      op ->
        try do
          run(client, op)
        after
          Store.release(op)
        end
    end
  end

  defp run(client, op) do
    {track, project} = Store.context(op)

    cond do
      op.action == :close ->
        close(client, op, track, project)

      track.sandbox_generation != op.generation or not is_nil(track.closed_at) ->
        retire(client, op, track, project)

      is_nil(project) ->
        retire(client, op, track, project)

      true ->
        open_step(client, op, track, project)
    end
  end

  defp open_step(client, %{phase: "rebuilding"} = op, track, project) do
    if Store.prior_pending?(op) do
      pause(op)
    else
      with :ok <- revoke_preview(track),
           :ok <- end_threads(client, track),
           :ok <- delete_resources(client, op),
           {:ok, op} <-
             Store.progress(
               op,
               %{
                 phase: "pending",
                 resource_ids:
                   Map.drop(op.resource_ids, ["sandbox_id", "vault_id", "conversation_id"])
               },
               sandbox_id: nil,
               vault_id: nil,
               conversation_id: nil,
               opened_at: nil,
               setup_error: nil,
               setup_error_code: nil,
               setup_request_id: nil
             ) do
        open_step(client, op, track, project)
      else
        _ -> defer(op, "sandbox_cleanup_pending")
      end
    end
  end

  defp open_step(client, %{phase: "pending"} = op, track, project) do
    cond do
      project.secrets_pending or project.secrets_generation != track.secrets_generation ->
        fail(client, op, track, project, "secrets_changed")

      not is_binary(op.resource_ids["source_vault_id"]) ->
        fail(client, op, track, project, "vault_copy_failed")

      true ->
        copy_secrets(client, op, track, project)
    end
  end

  defp open_step(client, %{phase: "copying"} = op, _track, _project) do
    with {:ok, vaults} <- Fountain.vaults(client) do
      case Enum.find(vaults, &(&1.name == vault_name(op))) do
        nil -> defer(op, "sandbox_outcome_unknown")
        vault -> remember_vault(client, op, vault.id)
      end
    end
  end

  defp open_step(client, %{phase: "vault_ready"} = op, _track, _project) do
    {track, project} = Store.context(op)

    with :ok <- fresh_secrets(track, project),
         :ok <- clone_token(client, project, op.resource_ids["vault_id"]),
         {:ok, op} <-
           Store.progress(op, %{phase: "launching"},
             sandbox_stage: if(project.repo_full_name, do: "cloning", else: "setup")
           ) do
      launch(client, op, track, project)
    else
      {:error, :secrets_changed} -> fail(client, op, track, project, "secrets_changed")
      {:error, :lost_lease} -> :ok
      {:error, _} -> fail(client, op, track, project, "clone_auth_failed")
    end
  end

  defp open_step(client, %{phase: "launching"} = op, track, project) do
    case Fountain.sandboxes(client) do
      {:ok, boxes} ->
        recover_allocation(client, op, track, project, Enum.find(boxes, &identity?(&1, op)))

      _ ->
        defer(op, "sandbox_outcome_unknown")
    end
  end

  defp open_step(client, %{phase: "setup"} = op, track, project) do
    Setup.advance(client, track.id)
    track = Store.get_track(track.id)

    cond do
      track.sandbox_generation != op.generation ->
        retire(client, op, track, project)
        publish(track)

      track.setup_state == "ready" ->
        record_ready(client, op, track)

      track.setup_state == "failed" ->
        fail(client, op, track, project, track.setup_error_code || "setup_failed")
        publish(track)

      true ->
        pause(op)
        publish(track)
    end
  end

  defp open_step(client, %{phase: "cleanup"} = op, track, project),
    do: cleanup(client, op, track, project)

  defp open_step(_client, _op, _track, _project), do: :ok

  defp record_ready(client, op, track) do
    result = Store.ready(op)
    # Readiness must reach subscribers even if best-effort tracing stalls or dies.
    publish(track)

    with {:ok, completed} <- result do
      OpenTrace.record(completed, Fountain.events_page(client, track.conversation_id, limit: 100))
      result
    end
  end

  # An absent listing cannot prove a timed-out mutation will not arrive later.
  # Keep its cleanup obligation; only bind an identity the provider can confirm.
  defp recover_allocation(_client, op, _track, _project, nil),
    do: defer(op, "sandbox_outcome_unknown")

  defp recover_allocation(client, op, track, project, box) do
    case Fountain.list_conversations(client, op.resource_ids["agent_id"]) do
      {:ok, conversations} ->
        recover_conversation(
          client,
          op,
          track,
          project,
          box,
          Enum.find(conversations, &(&1.sandbox_id == box.id))
        )

      _ ->
        defer(op, "sandbox_outcome_unknown")
    end
  end

  defp recover_conversation(client, op, _track, _project, _box, conversation)
       when not is_nil(conversation),
       do: bind(client, op, conversation)

  defp recover_conversation(client, op, track, project, box, nil) do
    with {:ok, op} <-
           Store.progress(op, %{resource_ids: Map.put(op.resource_ids, "sandbox_id", box.id)}),
         do: launch(client, op, track, project)
  end

  defp copy_secrets(client, op, track, project) do
    # Persist before POST; a successor discovers rather than allocating again.
    with {:ok, op} <- Store.progress(op, %{phase: "copying"}) do
      attrs = %{
        name: vault_name(op),
        metadata: %{
          ravix: %{
            track: op.track_id,
            generation: op.generation,
            operation: op.id
          }
        }
      }

      result = Fountain.copy_vault(client, op.resource_ids["source_vault_id"], attrs)
      copied(result, client, op, track, project)
    end
  end

  defp copied({:ok, vault}, client, op, _track, _project),
    do: remember_vault(client, op, vault.id)

  defp copied({:error, %Error{} = error}, client, op, track, project),
    do: mutation_failed(error, copy_code(error), client, op, track, project)

  defp copied(_, _client, op, _track, _project), do: defer(op, "sandbox_outcome_unknown")

  defp mutation_failed(error, code, client, op, track, project) do
    cond do
      Error.busy?(error) ->
        Store.progress(
          op,
          %{phase: "vault_ready", retry_at: DateTime.add(DateTime.utc_now(), 30)},
          setup_error: Error.public_message(error.code),
          setup_error_code: error.code
        )

      Error.unknown_outcome?(error) ->
        defer(op, "sandbox_outcome_unknown")

      true ->
        fail(client, op, track, project, code)
    end
  end

  defp launch(client, op, track, project) do
    launch = %Launch{
      agent_id: op.resource_ids["agent_id"],
      model: op.resource_ids["model"],
      environment_id: op.resource_ids["environment_id"],
      vault_id: op.resource_ids["vault_id"],
      sandbox_id: op.resource_ids["sandbox_id"],
      channel_id: op.resource_ids["channel_id"],
      title: track.title,
      prompt: Spec.open_dedicated_prompt(project, track)
    }

    launch = Maintenance.adopt(launch, project)
    launched(Fountain.create_conversation(client, launch), client, op, track, project)
  end

  defp launched({:ok, conversation}, client, op, _track, _project),
    do: bind(client, op, conversation)

  defp launched({:error, %Error{} = error}, client, op, track, project),
    do: mutation_failed(error, error.code || "setup_failed", client, op, track, project)

  defp launched(_, _client, op, _track, _project), do: defer(op, "sandbox_outcome_unknown")

  defp remember_vault(client, op, id) when is_binary(id) do
    resources = Map.put(op.resource_ids, "vault_id", id)

    with {:ok, next} <-
           Store.progress(op, %{phase: "vault_ready", resource_ids: resources}, vault_id: id),
         do: run(client, next)
  end

  defp remember_vault(_client, op, _id), do: defer(op, "sandbox_outcome_unknown")

  defp bind(client, op, conversation) do
    if is_binary(conversation.sandbox_id) do
      with {:ok, next} <- Store.bind(op, conversation.id, conversation.sandbox_id),
           do: run(client, next)
    else
      defer(op, "sandbox_outcome_unknown")
    end
  end

  defp close(client, %{resource_ids: %{"legacy" => true}} = op, track, _project) do
    with true <- Ravix.Config.retire_shared_machines?() or op.resource_ids["maintenance"] == true,
         {:ok, op} <- discover_shared(client, op),
         :ok <- retire_shared_dependents(client, op, track),
         :ok <- delete_box(client, op.resource_ids["sandbox_id"]),
         {:ok, _} <- Store.finish_shared(op, track) do
      MachineCache.forget_project(track.project_id)
      publish(track)
    else
      false ->
        Store.finish_shared(op, track, %{code: "retirement_disabled"})

      _ when op.attempts >= 5 ->
        Store.finish_shared(op, track, %{code: "sandbox_cleanup_pending"})

      _ ->
        defer(op, "sandbox_cleanup_pending")
    end
  end

  defp close(client, op, track, project) do
    if Store.prior_pending?(op), do: pause(op), else: close_owned(client, op, track, project)
  end

  defp retire_shared_dependents(client, op, track) do
    ids = op.resource_ids["shared_tracks"] || [track.id]

    Enum.reduce_while(ids, :ok, fn id, :ok ->
      sibling = Store.get_track(id)

      with true <- sibling.project_id == track.project_id and sibling.sandbox_layout == :shared,
           :ok <- revoke_preview(sibling),
           :ok <- end_threads(client, sibling) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :cleanup_pending}}
      end
    end)
  end

  defp close_owned(client, op, track, project) do
    with :ok <- revoke_preview(track),
         :ok <- end_threads(client, track),
         :ok <- delete_resources(client, op) do
      Store.progress(op, %{phase: "done", completed_at: DateTime.utc_now(), error: nil},
        sandbox_state: :terminated,
        sandbox_stage: "terminated",
        closed_at: DateTime.utc_now()
      )

      publish(track)
      if project, do: MachineCache.forget_project(project.id)
    else
      _ -> defer(op, "sandbox_cleanup_pending")
    end
  end

  defp discover_shared(_client, %{resource_ids: %{"sandbox_id" => id}} = op) when is_binary(id),
    do: {:ok, op}

  defp discover_shared(_client, %{resource_ids: %{"agent_id" => nil}}),
    do: {:error, :unknown_home_identity}

  defp discover_shared(client, op) do
    with {:ok, boxes} <- Fountain.sandboxes(client) do
      case Enum.find(boxes, &identity?(&1, op)) do
        nil -> {:ok, op}
        box -> Store.progress(op, %{resource_ids: Map.put(op.resource_ids, "sandbox_id", box.id)})
      end
    end
  end

  defp retire(client, op, track, project) do
    case op.phase do
      "copying" ->
        with {:ok, vaults} <- Fountain.vaults(client),
             vault when not is_nil(vault) <- Enum.find(vaults, &(&1.name == vault_name(op))),
             {:ok, op} <-
               Store.progress(op, %{
                 phase: "cleanup",
                 resource_ids: Map.put(op.resource_ids, "vault_id", vault.id)
               }) do
          cleanup(client, op, track, project)
        else
          _ -> pause(op)
        end

      "launching" ->
        with {:ok, boxes} <- Fountain.sandboxes(client),
             box when not is_nil(box) <- Enum.find(boxes, &identity?(&1, op)),
             {:ok, op} <-
               Store.progress(op, %{
                 phase: "cleanup",
                 resource_ids: Map.put(op.resource_ids, "sandbox_id", box.id)
               }) do
          cleanup(client, op, track, project)
        else
          _ -> pause(op)
        end

      _ ->
        cleanup(client, op, track, project)
    end
  end

  defp fail(client, op, track, project, code) do
    error = %{code: code, message: Error.public_message(code)}

    with {:ok, op} <-
           Store.progress(op, %{phase: "cleanup", error: error},
             setup_state: "failed",
             setup_error: error.message,
             setup_error_code: code,
             sandbox_state: :failed,
             sandbox_stage: "failed"
           ) do
      # ownership: the durable operation was admitted by Access.track_access and require_owner_or_cutter.
      Ravix.PromptQueue.Store.fail_setup(
        track.id,
        Setup.failure_message() <> " " <> error.message,
        code
      )

      publish(track)
      cleanup(client, op, track, project)
    end
  end

  defp cleanup(client, op, track, _project) do
    case delete_resources(client, op) do
      :ok ->
        failed? = track.sandbox_generation == op.generation and not is_nil(op.error)

        Store.progress(
          op,
          %{
            phase: if(failed?, do: "failed", else: "done"),
            completed_at: if(failed?, do: nil, else: DateTime.utc_now()),
            cleanup: %{}
          },
          vault_id: nil,
          sandbox_id: nil
        )

      _ ->
        Store.progress(op, %{
          phase: "cleanup",
          cleanup: %{pending: true},
          retry_at: DateTime.add(DateTime.utc_now(), 15)
        })
    end
  end

  defp delete_resources(client, op) do
    with :ok <- delete_box(client, op.resource_ids["sandbox_id"]),
         do: delete_vault(client, op.resource_ids["vault_id"])
  end

  defp delete_box(_client, nil), do: :ok

  defp delete_box(client, id) do
    with :ok <- accept_reset(Fountain.reset_sandbox(client, id)),
         do: confirm_deleted(Fountain.sandbox(client, id), &Error.sandbox_gone?/1)
  end

  # A terminal retained row refuses another DELETE. This can also mean a
  # non-persistent sandbox, so only the following GET confirms destruction.
  defp accept_reset({:error, %Error{status: 422, code: "sandbox_not_resettable"}}), do: :ok
  defp accept_reset(result), do: result

  defp delete_vault(_client, nil), do: :ok

  defp delete_vault(client, id) do
    with :ok <- accept_missing(Fountain.delete_vault(client, id)),
         do: confirm_deleted(Fountain.get_vault(client, id), &Error.vault_gone?/1)
  end

  defp accept_missing({:error, %Error{status: 404}}), do: :ok
  defp accept_missing(result), do: result

  # Fountain retains destroyed sandbox rows; vault rows are actually deleted.
  defp confirm_deleted({:ok, %Fountain.Shapes.Sandbox{status: status}}, _gone?)
       when status in ["terminated", "failed"],
       do: :ok

  defp confirm_deleted({:error, %Error{} = error}, gone?) do
    if gone?.(error), do: :ok, else: {:error, error}
  end

  defp confirm_deleted(_, _), do: {:error, :deletion_pending}

  defp end_threads(client, track) do
    # ownership: the durable close owns every thread of this track.
    Ravix.Tracks.Store.threads_of(track.id)
    |> Enum.flat_map(&(&1.previous_conversation_ids ++ [&1.conversation_id]))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn conversation_id, :ok ->
      case terminate(client, conversation_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp terminate(_client, nil), do: :ok

  defp terminate(client, id) do
    case Fountain.terminate(client, id) do
      {:error, %Error{status: 404}} -> :ok
      result -> result
    end
  end

  defp revoke_preview(track) do
    # ownership: the durable close was admitted by Access.track_access and require_owner_or_cutter.
    Lifecycle.stop_service(track.id, :cleanup)
  end

  defp clone_token(client, %{installation_id: id}, vault_id)
       when is_integer(id) and is_binary(vault_id),
       do: Machine.refresh_clone_token(%{installation_id: id, vault_id: vault_id}, client)

  defp clone_token(_client, _project, _vault), do: :ok

  defp fresh_secrets(track, project) do
    if not project.secrets_pending and track.secrets_generation == project.secrets_generation,
      do: :ok,
      else: {:error, :secrets_changed}
  end

  defp identity?(box, op),
    do:
      box.status not in ["terminated", "failed"] and
        is_binary(op.resource_ids["agent_id"]) and box.agent_id == op.resource_ids["agent_id"] and
        box.environment_id == op.resource_ids["environment_id"] and
        box.vault_id == op.resource_ids["vault_id"]

  defp vault_name(op), do: "ravix-track-#{op.track_id}-#{op.generation}"
  defp copy_code(%Error{code: "secret_not_copyable"}), do: "secret_not_copyable"
  defp copy_code(_), do: "vault_copy_failed"
  defp pause(op), do: Store.progress(op, %{retry_at: DateTime.add(DateTime.utc_now(), 5)})

  defp defer(op, code) do
    Store.progress(
      op,
      %{
        error: %{code: code, message: Error.public_message(code)},
        retry_at: DateTime.add(DateTime.utc_now(), 15)
      },
      setup_error: Error.public_message(code),
      setup_error_code: code,
      setup_state: if(code == "sandbox_outcome_unknown", do: "retry", else: "pending")
    )

    if code == "sandbox_outcome_unknown", do: publish(Store.get_track(op.track_id))
  end

  defp publish(track), do: Hub.publish(track.project_id, :tracks, track_id: track.id)
end

defmodule Ravix.Tracks.CredentialRecovery do
  @moduledoc "Replace a rejected inference session on the same disk, keeping the thread's history."
  alias Ravix.Accounts.Inference
  alias Ravix.Fountain
  alias Ravix.Fountain.Error
  alias Ravix.Fountain.Launch
  alias Ravix.Hub
  alias Ravix.Projects.Project
  alias Ravix.Projects.RuntimeAgents
  alias Ravix.Tracks.Follower
  alias Ravix.Tracks.Sandbox.Maintenance
  alias Ravix.Tracks.Store

  def enabled?(track, project),
    do: track.sandbox_layout == :dedicated and Project.maintenance?(project)

  # ownership: PromptQueue.Server.access established Access.thread_access for the queued sender.
  def reject(track, project, thread_id) do
    if enabled?(track, project), do: Store.recover_credentials(track, thread_id), else: :disabled
  end

  # No database connection is held while resolving the provider. A lost caller leaves
  # an attempted identity, which subsequent workers only reconcile, never reallocate.
  def prepare(client, track, project, thread_id) do
    if enabled?(track, project) do
      case Store.thread(track.id, thread_id) do
        %{credential_recovery: nil} -> :ok
        thread -> recover(client, track, project, thread)
      end
    else
      :ok
    end
  end

  defp recover(client, track, project, thread) do
    owner = RuntimeAgents.owner(project)
    runtime = thread.runtime || Project.home_runtime(project)

    with {:ok, true} <- Inference.usable?(owner, runtime, fresh: true),
         {:ok, agent_id} <-
           RuntimeAgents.ensure(project, client, runtime, thread.model, isolated: true),
         :ok <- Maintenance.prepare(client, track, project) do
      resolve(client, track, project, thread, agent_id)
    else
      _ -> :waiting
    end
  end

  defp resolve(
         client,
         track,
         project,
         %{credential_recovery: %{"attempted" => false}} = thread,
         agent_id
       ) do
    case Store.attempt_credential_recovery(thread) do
      {:ok, thread} ->
        launch =
          %Launch{
            agent_id: agent_id,
            model: thread.model,
            environment_id: project.environment_id,
            vault_id: track.vault_id,
            sandbox_id: track.sandbox_id,
            channel_id: thread.credential_recovery["channel"],
            title: thread.title,
            prompt: nil
          }
          |> Maintenance.adopt(project)

        result = Fountain.create_conversation(client, launch)
        created(result, client, track, project, thread)

      _ ->
        :waiting
    end
  end

  defp resolve(client, track, project, thread, agent_id) do
    with {:ok, conversations} <- Fountain.list_conversations(client, agent_id),
         [conversation] <-
           Enum.filter(
             conversations,
             &(&1.channel_id == thread.credential_recovery["channel"] and
                 &1.sandbox_id == track.sandbox_id)
           ) do
      created({:ok, conversation}, client, track, project, thread)
    else
      _ -> :waiting
    end
  end

  defp created(
         {:ok, %{sandbox_id: sandbox, id: id}},
         _client,
         %{sandbox_id: sandbox} = track,
         project,
         thread
       ) do
    case Store.bind_credential_recovery(track, thread, id) do
      {:ok, :ok} ->
        Follower.rebound(thread.id, thread.conversation_id)
        Hub.publish(project.id, :tracks, track_id: track.id)
        :rebound

      _ ->
        :waiting
    end
  end

  defp created({:error, %Error{} = error}, _client, _track, _project, thread) do
    if Error.rejected?(error), do: Store.retry_credential_recovery(thread)
    :waiting
  end

  defp created(_, _, _, _, _), do: :waiting
end

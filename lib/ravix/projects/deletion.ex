defmodule Ravix.Projects.Deletion do
  @moduledoc "Durable project deletion: retire track resources before their shared templates."
  alias Ravix.Fountain
  alias Ravix.Hub
  alias Ravix.Projects
  alias Ravix.Projects.Store
  alias Ravix.Tracks.Sandbox

  # The scoped Projects.destroy/2 admitted the owner before persisting this intent.
  def request(project) do
    Ravix.Cluster.project_mutation(project.id, :shared_machine, fn -> request_locked(project) end)
  end

  defp request_locked(project) do
    with {:ok, :ok} <- Store.request_deletion(project) do
      Hub.publish(project.id, :tracks)
      :ok
    end
  end

  def retire_shared(project, client) do
    Ravix.Cluster.project_mutation(project.id, :shared_machine, fn ->
      retire_shared_locked(project, client)
    end)
  end

  def retire_shared_locked(project, client) do
    outcomes = Enum.map(Store.resources(project), &retire_resource(&1, client))

    case Enum.find(outcomes, &match?({:error, _}, &1)) do
      nil -> {:ok, %Projects.Machine.Rebuild{removed: ["shared machine"], failed: []}}
      error -> error
    end
  end

  defp retire_resource(project, client) do
    # ownership: Access.project_of admitted the shared-only rebuild.
    with {:ok, :ok} <- Sandbox.Store.retire_shared_tracks(project) do
      operations = Sandbox.Store.shared_retirements(project)
      for op <- operations, do: Sandbox.advance(client, op.id)
      retirement_result(project, operations)
    end
  end

  defp retirement_result(project, operations) do
    # ownership: Access.project_of admitted these shared-only retirement operations.
    failed? = Enum.any?(operations, &(Sandbox.Store.get_operation(&1.id).phase == "failed"))

    cond do
      Store.for_resource(Store.get_project(project.id), project.resource_id).shared_machine_retiring ->
        {:error,
         {:conflict, "machine_cleanup_pending",
          "The shared machine is still being removed. Try again shortly. Dedicated tracks are unaffected."}}

      failed? ->
        {:error,
         {:conflict, "machine_cleanup_failed",
          "The shared machine could not be removed after repeated attempts. Dedicated tracks are unaffected."}}

      true ->
        {:ok, %Projects.Machine.Rebuild{removed: ["shared machine"], failed: []}}
    end
  end

  def reconcile(client) do
    # ownership: the durable project deletion was admitted by Access.project_of/2.
    Enum.each(Store.pending_deletions(), &advance(client, &1))
  end

  def advance(client, project) do
    # ownership: the durable project deletion admitted by Access.project_of owns its track cleanup.
    if Sandbox.Store.project_clean?(project.id) do
      result =
        Enum.reduce_while(Store.resources(project), :ok, fn resource, :ok ->
          delete_resource(client, resource)
        end)

      with :ok <- result do
        Store.archive(project.id)
        Hub.publish(project.id, :tracks)
      end
    end
  end

  defp delete_resource(client, resource) do
    with :ok <- Projects.RuntimeAgents.retire(resource, client),
         :ok <- absent(Fountain.delete_agent(client, resource.agent_id)),
         :ok <- delete_vault(client, resource.vault_id),
         :ok <- absent(Fountain.delete_environment(client, resource.environment_id)) do
      {:cont, :ok}
    else
      error -> {:halt, error}
    end
  end

  defp delete_vault(_client, nil), do: :ok
  defp delete_vault(client, id), do: absent(Fountain.delete_vault(client, id))
  defp absent({:error, %Fountain.Error{status: 404}}), do: :ok
  defp absent(result), do: result
end

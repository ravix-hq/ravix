defmodule Ravix.Tracks.Sandbox.Maintenance do
  @moduledoc "Preparation of one dedicated workspace; no sibling agent or disk mutations."
  alias Ravix.Projects.{Machine, Project, RuntimeAgents}
  alias Ravix.Tracks.Billing
  alias Ravix.Tracks.Sandbox.Store

  # ownership: Access.track_access or a durable setup/queue operation admitted this track.
  def prepare(client, track, project) do
    if Billing.maintained?(track, project) do
      with :ok <- clone_token(client, track, project) do
        current?(track)
      end
    else
      project =
        if track.sandbox_layout == :dedicated,
          do: %{project | vault_id: track.vault_id},
          else: project

      Ravix.Projects.prepare_machine(project, client)
    end
  end

  defp current?(track) do
    case Store.get_track(track.id) do
      %{sandbox_generation: generation, vault_id: vault, closed_at: nil, sandbox_state: state}
      when generation == track.sandbox_generation and vault == track.vault_id and
             state not in [:closing, :terminated] ->
        :ok

      _ ->
        {:error,
         {:conflict, "machine_changed",
          "This track's machine changed. Retry after setup finishes."}}
    end
  end

  defp clone_token(client, track, %{repo_full_name: repo, installation_id: installation})
       when is_binary(repo) and repo != "" and is_integer(installation) do
    if is_binary(track.vault_id),
      do:
        Machine.refresh_clone_token(
          %{vault_id: track.vault_id, installation_id: installation},
          client
        ),
      else:
        {:error,
         {:conflict, "machine_not_ready",
          "This track's machine is not ready. Your prompt is saved."}}
  end

  defp clone_token(_client, _track, _project), do: :ok

  @doc """
  Adopt the owner's source on this conversation, never by changing a shared
  agent. Creator billing binds through `Ravix.Tracks.Billing.bind/3`, which
  does this for an owner-billed track and names the creator's set otherwise.
  """
  def adopt(launch, project) do
    if Project.maintenance?(project),
      do: %{launch | inference_credential_id: RuntimeAgents.owner(project).credential_set_id},
      else: launch
  end
end

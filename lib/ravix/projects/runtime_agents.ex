defmodule Ravix.Projects.RuntimeAgents do
  @moduledoc "Project runtime agents. Callers first establish project or track access."
  alias Ravix.Fountain
  alias Ravix.Fountain.Error
  alias Ravix.Projects
  alias Ravix.Projects.{Project, Store}

  # ownership: callers enter through Access.project_access/2 or Access.track_access/2.
  # Subscription ownership follows the project's owner, never the collaborating member.
  def owner(project), do: Ravix.Accounts.Store.get_user(project.user_id)

  def ids(project) do
    [project.agent_id | Enum.map(Store.runtime_agents(project.id), & &1.agent_id)]
    |> Enum.reject(&is_nil/1)
  end

  def home_runtime(project, client, sandbox_id) do
    agents = Store.runtime_agents(project.id)

    if agents == [] or is_nil(sandbox_id) do
      {:ok, project.shared_home_runtime || Project.home_runtime(project)}
    else
      with {:ok, sandbox} <- Fountain.sandbox(client, sandbox_id),
           do: identify_home(project, agents, sandbox.agent_id)
    end
  end

  defp identify_home(project, agents, id) do
    cond do
      id == project.agent_id ->
        {:ok, Project.home_runtime(project)}

      agent = Enum.find(agents, &(&1.agent_id == id and not is_nil(id))) ->
        {:ok, agent.runtime}

      true ->
        {:error,
         {:conflict, "unknown_home_runtime", "The machine's home agent could not be established."}}
    end
  end

  def pin_shared_home(project, selection, machine) do
    wanted = if machine, do: selection.home, else: selection.runtime

    case Store.claim_shared_home(project.id, wanted, project.agent_id) do
      {:ok, ^wanted} ->
        :ok

      _ ->
        {:error,
         {:conflict, "home_runtime_pending",
          "Wait for the home agent to open the machine before attaching another agent."}}
    end
  end

  def ensure(project, client, runtime, model, opts \\ [])
  def ensure(%{runtime_agents_retiring: true}, _client, _runtime, _model, _opts), do: pending()

  def ensure(project, client, runtime, model, opts) do
    case Store.live_project(project.id) do
      %{runtime_agents_retiring: false, agent_id: id} = fresh when id == project.agent_id ->
        ensure_current(fresh, client, runtime, model, opts)

      _ ->
        pending()
    end
  end

  defp ensure_current(project, client, runtime, model, opts) do
    isolated? = Keyword.get(opts, :isolated, false) and Project.maintenance?(project)

    if runtime == Project.home_runtime(project) do
      adopt_home(project, client, isolated?)
    else
      ensure_other(project, client, runtime, model, isolated?)
    end
  end

  defp adopt_home(project, client, isolated?) do
    if isolated?,
      do: allow_source(project, client, project.agent_id, project.credential_set_id),
      else:
        with(
          :ok <- Projects.Machine.adopt_credentials(project, client),
          do: {:ok, project.agent_id}
        )
  end

  defp ensure_other(project, client, runtime, model, isolated?) do
    case Enum.find(Store.runtime_agents(project.id), &(&1.runtime == runtime)) do
      nil -> reserve_and_create(project, client, runtime, model)
      %{agent_id: nil} -> pending()
      agent -> adopt(project, client, agent, isolated?)
    end
  end

  defp reserve_and_create(project, client, runtime, model) do
    case Store.reserve_runtime(project.id, runtime, project.agent_id) do
      :ok -> create(project, client, runtime, model)
      {:error, _} -> pending()
    end
  end

  defp create(project, client, runtime, model) do
    set = owner(project).credential_set_id

    body = %{
      name: "Ravix #{project.id} #{runtime}",
      runtime: runtime,
      model: model,
      sandbox_mode: "persistent",
      system: Projects.compose_system(project),
      environment_id: project.environment_id,
      vault_id: project.vault_id,
      inference_credential_id: set,
      metadata: %{ravix: %{project: project.id}}
    }

    case Fountain.create_agent(client, body) do
      {:ok, %{"id" => id}} when is_binary(id) ->
        Store.bind_runtime(project.id, runtime, id, set)
        Ravix.MachineCache.forget_project(project.id)
        {:ok, id}

      {:error, %Error{} = error} ->
        # An uncertain POST must never be retried into a duplicate runtime agent.
        # Leave its reservation for operator reconciliation, including process death.
        unless Error.unknown_outcome?(error), do: Store.forget_runtime(project.id, runtime)
        {:error, error}

      _ ->
        pending()
    end
  end

  defp adopt(project, client, agent, isolated?) do
    set = owner(project).credential_set_id

    cond do
      isolated? ->
        allow_source(project, client, agent.agent_id, agent.credential_set_id)

      set == agent.credential_set_id ->
        {:ok, agent.agent_id}

      true ->
        with {:ok, _} <-
               Fountain.update_agent(client, agent.agent_id, %{inference_credential_id: set}) do
          Store.bind_runtime(project.id, agent.runtime, agent.agent_id, set)
          {:ok, agent.agent_id}
        end
    end
  end

  # Conversation overrides must be admitted by the agent. Add only the owner's
  # source to its allowlist; never change its default or any sibling session.
  defp allow_source(project, client, agent_id, default_source) do
    source = owner(project).credential_set_id

    if source == default_source do
      {:ok, agent_id}
    else
      with {:ok, agent} <- Fountain.get_agent(client, agent_id),
           :ok <- allow_source_id(client, agent_id, agent, source),
           do: {:ok, agent_id}
    end
  end

  defp allow_source_id(client, agent_id, agent, source) do
    allowed = agent["allowed_inference_credential_ids"] || []

    if source == agent["inference_credential_id"] or source in allowed do
      :ok
    else
      with {:ok, _} <-
             Fountain.update_agent(client, agent_id, %{
               allowed_inference_credential_ids: Enum.uniq(allowed ++ [source])
             }),
           do: :ok
    end
  end

  def retire(project, client) do
    Store.retire_runtimes(project.id)

    Enum.reduce_while(Store.runtime_agents(project.id), :ok, fn agent, :ok ->
      case retire_one(project, client, agent) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp retire_one(_project, _client, %{agent_id: nil}), do: pending()

  defp retire_one(project, client, agent) do
    case Fountain.delete_agent(client, agent.agent_id) do
      :ok -> Store.forget_runtime(project.id, agent.runtime)
      {:error, %Error{status: 404}} -> Store.forget_runtime(project.id, agent.runtime)
      error -> error
    end
  end

  defp pending do
    {:error,
     {:conflict, "runtime_agent_pending",
      "This agent is being created or needs reconciliation after an uncertain response. Try again later; an administrator must reconcile an interrupted creation."}}
  end
end

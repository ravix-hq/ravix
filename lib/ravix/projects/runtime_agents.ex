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

  # `payer_set:` is a creator-billed track's payer's set (ADR 0009 phase 6).
  # Such a track is always isolated, whatever the owner's rollout cohort says:
  # its conversations name that set, so the agent must admit it and its
  # default must never be moved to make room for it.
  defp ensure_current(project, client, runtime, model, opts) do
    payer_set = Keyword.get(opts, :payer_set)

    isolated =
      cond do
        is_binary(payer_set) -> {:payer, payer_set}
        Keyword.get(opts, :isolated, false) and Project.maintenance?(project) -> :owner
        true -> false
      end

    if runtime == Project.home_runtime(project) do
      adopt_home(project, client, isolated)
    else
      ensure_other(project, client, runtime, model, isolated)
    end
  end

  defp adopt_home(project, client, {:payer, set}),
    do: admit_payer(client, project.agent_id, set)

  defp adopt_home(project, client, :owner),
    do: allow_source(project, client, project.agent_id, project.credential_set_id)

  defp adopt_home(project, client, false) do
    with :ok <- Projects.Machine.adopt_credentials(project, client), do: {:ok, project.agent_id}
  end

  defp ensure_other(project, client, runtime, model, isolated) do
    case Enum.find(Store.runtime_agents(project.id), &(&1.runtime == runtime)) do
      nil ->
        with {:ok, id} <- reserve_and_create(project, client, runtime, model),
             do: admitted(project, client, %{agent_id: id, credential_set_id: nil}, isolated)

      %{agent_id: nil} ->
        pending()

      agent ->
        adopt(project, client, agent, isolated)
    end
  end

  # A runtime agent made just now for a creator-billed thread still has to
  # admit that creator before anything names their set.
  defp admitted(_project, client, agent, {:payer, set}),
    do: admit_payer(client, agent.agent_id, set)

  defp admitted(_project, _client, agent, _isolated), do: {:ok, agent.agent_id}

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
      # Explicit, never nil: Fountain reads a nil allowlist as "every set on
      # the account", and every Ravix person's set is on this one account.
      # Creators are admitted one by one (`admit_payer/3`).
      allowed_inference_credential_ids: [],
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

  defp adopt(_project, client, agent, {:payer, set}), do: admit_payer(client, agent.agent_id, set)

  defp adopt(project, client, agent, isolated) do
    set = owner(project).credential_set_id

    cond do
      isolated == :owner ->
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

    if source == default_source,
      do: {:ok, agent_id},
      else:
        Ravix.Cluster.agent_allowlist(agent_id, fn -> allow_owner(client, agent_id, source) end)
  end

  defp allow_owner(client, agent_id, source) do
    with {:ok, agent} <- Fountain.get_agent(client, agent_id),
         {:ok, _} <- allow_source_id(client, agent_id, agent, source),
         do: {:ok, agent_id}
  end

  @doc """
  Admit a creator-billed track's payer's set on a project or runtime agent
  (`docs/creator-billing.md` §1).

  Every writer of an agent's allowlist goes through
  `Ravix.Cluster.agent_allowlist/2`, so this read, add and write cannot lose
  a concurrent admission, and the list is read back afterwards: only a set
  Fountain now reports admitted is `{:ok, agent_id}`. Anything else is a
  tagged refusal and the caller launches nothing, which is what fails closed
  means here --- Fountain would refuse the launch too
  (`inference_credential_not_allowed`), and the agent's default, the
  project owner's set, is never what a creator-billed thread falls back to.
  The set comes from the track's recorded payer, never from a request.
  """
  @spec admit_payer(Fountain.Client.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def admit_payer(client, agent_id, set) when is_binary(agent_id) and is_binary(set) do
    Ravix.Cluster.agent_allowlist(agent_id, fn ->
      with {:ok, agent} <- Fountain.get_agent(client, agent_id),
           {:ok, changed?} <- allow_source_id(client, agent_id, agent, set),
           :ok <- confirm_admitted(client, agent_id, set, changed?) do
        {:ok, agent_id}
      end
    end)
  end

  def admit_payer(_client, _agent_id, _set), do: not_admitted()

  defp confirm_admitted(_client, _agent_id, _set, false), do: :ok

  defp confirm_admitted(client, agent_id, set, true) do
    case Fountain.get_agent(client, agent_id) do
      {:ok, agent} -> if admits?(agent, set), do: :ok, else: not_admitted()
      _ -> not_admitted()
    end
  end

  @doc "Whether a Fountain agent, as its JSON reads, admits `set` on a conversation."
  @spec admits?(map(), String.t()) :: boolean()
  def admits?(agent, set) when is_map(agent) and is_binary(set) do
    set == agent["inference_credential_id"] or
      (is_list(agent["allowed_inference_credential_ids"]) and
         set in agent["allowed_inference_credential_ids"])
  end

  @doc """
  Give an agent Fountain reads as open (a nil allowlist: every set on the
  account) an explicit empty list, under the same lock as every other
  allowlist writer. Idempotent: an agent that already has a list, empty or
  not, is left alone. The activation runbook's step for agents made before
  runtime agents were created with `[]`.
  """
  @spec close_allowlist(Fountain.Client.t(), String.t()) ::
          {:ok, :closed | :already} | {:error, term()}
  def close_allowlist(client, agent_id) when is_binary(agent_id) do
    Ravix.Cluster.agent_allowlist(agent_id, fn ->
      with {:ok, agent} <- Fountain.get_agent(client, agent_id),
           do: close_open(client, agent_id, agent)
    end)
  end

  defp close_open(_client, _agent_id, %{"allowed_inference_credential_ids" => list})
       when is_list(list),
       do: {:ok, :already}

  defp close_open(client, agent_id, _agent) do
    with {:ok, _} <-
           Fountain.update_agent(client, agent_id, %{allowed_inference_credential_ids: []}),
         {:ok, %{"allowed_inference_credential_ids" => list}} when is_list(list) <-
           Fountain.get_agent(client, agent_id) do
      {:ok, :closed}
    else
      {:error, _} = error -> error
      _ -> not_admitted()
    end
  end

  defp not_admitted,
    do:
      {:error,
       {:conflict, "payer_not_admitted",
        "This track's agent has not admitted its payer's account yet. Your prompt is saved; try again shortly."}}

  defp allow_source_id(client, agent_id, agent, source) do
    allowed = agent["allowed_inference_credential_ids"] || []

    if admits?(agent, source) do
      {:ok, false}
    else
      with {:ok, _} <-
             Fountain.update_agent(client, agent_id, %{
               allowed_inference_credential_ids: Enum.uniq(allowed ++ [source])
             }),
           do: {:ok, true}
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

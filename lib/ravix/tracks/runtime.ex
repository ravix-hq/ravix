defmodule Ravix.Tracks.Runtime do
  @moduledoc "Thread choices after the caller has admitted project or track access."
  alias Ravix.Accounts.{Inference, ThreadPreference}
  alias Ravix.AgentName
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.MachineCache
  alias Ravix.Projects.{RuntimeAgents, Settings}

  @doc """
  The harnesses a thread or a new track can offer, and which is preselected.

  `opts[:payer]` is whoever pays for the thread: the track's creator on a
  creator-billed track, the person opening a track while creator billing is
  on, and otherwise the project's owner (ADR 0005). `connected` is theirs,
  never the viewer's, so a harness the payer has not connected is offered
  disabled rather than run on somebody else's. `owner_login` and `owner?`
  name that payer; `billing` says which rule chose them.
  """
  def options(user, project, client, last_runtime \\ nil, machine \\ :discover, opts \\ []) do
    owner = payer(project, opts)

    with {:ok, machine} <- options_machine(client, project, machine),
         {:ok, home} <- RuntimeAgents.home_runtime(project, client, machine && machine.sandbox_id),
         {:ok, usable} <- Inference.usable_agents(owner),
         {:ok, catalog} <- MachineCache.catalog(client),
         {:ok, preference} <- ThreadPreference.get(user, catalog) do
      runtimes =
        Enum.map(["claude", "codex"], fn runtime ->
          %{
            runtime: runtime,
            connected: runtime in Enum.map(usable, &to_string/1),
            enabled: runtime == home or Ravix.Config.dedicated_opens_enabled?(user),
            models: Catalog.models_for(catalog, runtime)
          }
        end)

      selection = resolve(user, project, last_runtime, home, usable, catalog, preference)

      {:ok,
       %{
         runtimes: runtimes,
         runtime: selection.runtime,
         model: selection.model,
         source: selection.source,
         home_runtime: home,
         owner_login: owner.login,
         owner?: user.id == owner.id,
         billing: if(Keyword.has_key?(opts, :payer_set), do: :creator, else: :owner)
       }}
    end
  end

  defp options_machine(client, project, :discover), do: MachineCache.machine_of(client, project)
  defp options_machine(_client, _project, machine), do: {:ok, machine}

  @doc """
  Choose and prepare the harness for a new thread or track.

  `opts`: `isolated:` as `RuntimeAgents.ensure/5` reads it; `payer:`, whose
  credentials must be usable for the harness (default the project's owner);
  and `payer_set:`, on a creator-billed track, the set every agent it uses
  must admit. A harness the payer has not connected is refused, whoever asks.
  """
  def select(user, project, client, attrs, last_runtime \\ nil, sandbox_id \\ nil, opts \\ []) do
    payer = payer(project, opts)

    with {:ok, home} <- RuntimeAgents.home_runtime(project, client, sandbox_id),
         {:ok, selection} <-
           default_selection(user, project, client, attrs, last_runtime, home, payer),
         runtime = nonblank(attrs["runtime"]) || selection.runtime,
         model = nonblank(attrs["model"]) || selection.model,
         :ok <- gate(user, %{project | runtime: home}, runtime),
         :ok <- usable(payer, runtime),
         {:ok, selected_model} <- select_model(client, project, runtime, model),
         {:ok, agent_id} <-
           RuntimeAgents.ensure(
             project,
             client,
             runtime,
             selected_model,
             Keyword.take(opts, [:isolated, :payer_set])
           ),
         :ok <- remember_pick(user, client, attrs, runtime, selected_model) do
      {:ok, %{runtime: runtime, model: selected_model, agent_id: agent_id, home: home}}
    end
  end

  defp usable(payer, runtime) do
    case Inference.usable?(payer, runtime, fresh: true) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         {:conflict, "agent_not_connected",
          "#{payer.login} hasn't connected #{AgentName.label(runtime)}."}}

      error ->
        error
    end
  end

  # ADR 0005: the project's owner pays unless the caller names somebody else,
  # which only `Ravix.Tracks.Billing` does, from a track's recorded payer or
  # for the person opening a creator-billed track (ADR 0009 phase 6).
  defp payer(project, opts),
    do: Keyword.get_lazy(opts, :payer, fn -> RuntimeAgents.owner(project) end)

  defp default_selection(_user, _project, _client, %{"runtime" => runtime}, _last, _home, _payer)
       when is_binary(runtime) and runtime != "",
       do: {:ok, %{runtime: runtime, model: nil}}

  defp default_selection(user, project, client, _attrs, last, home, payer) do
    with {:ok, usable} <- Inference.usable_agents(payer, fresh: true),
         {:ok, catalog} <- MachineCache.catalog(client),
         {:ok, preference} <- ThreadPreference.get(user, catalog) do
      {:ok, resolve(user, project, last, home, usable, catalog, preference)}
    end
  end

  defp resolve(user, project, last, home, usable, catalog, preference) do
    usable = Enum.map(usable, &to_string/1)

    allowed = &allowed?(user, project, home, usable, &1)

    cond do
      preference && allowed.(preference.runtime) && preference.model ->
        Map.put(preference, :source, :person)

      last && allowed.(last) ->
        %{runtime: last, model: fallback_model(project, catalog, last), source: :track}

      true ->
        runtime = if allowed.(project.runtime), do: project.runtime, else: home
        %{runtime: runtime, model: fallback_model(project, catalog, runtime), source: :project}
    end
  end

  defp allowed?(user, project, home, usable, runtime) do
    runtime in usable and (runtime == home or Ravix.Config.dedicated_opens_enabled?(user)) and
      (not Settings.default_only?(project) or runtime == project.runtime)
  end

  defp fallback_model(%{runtime: runtime, model: model}, _catalog, runtime), do: model

  defp fallback_model(_project, catalog, runtime),
    do: Catalog.default_model(catalog, runtime)

  defp remember_pick(user, client, attrs, runtime, model) do
    if attrs["preference_explicit"] == "true" and
         (nonblank(attrs["runtime"]) || nonblank(attrs["model"])),
       do: ThreadPreference.remember(user, runtime, model, client),
       else: :ok
  end

  defdelegate pin_shared_home(project, selection, machine), to: RuntimeAgents

  def gate(user, project, runtime) do
    cond do
      runtime not in ["claude", "codex"] ->
        {:error, {:unprocessable, "invalid_runtime", "Choose Claude Code or Codex."}}

      runtime == project.runtime or Ravix.Config.dedicated_opens_enabled?(user) ->
        :ok

      true ->
        {:error,
         {:conflict, "guest_runtime_disabled",
          "#{AgentName.label(runtime)} threads on this project aren't available yet."}}
    end
  end

  def select_model(_client, %{runtime: runtime, model: model}, runtime, wanted)
      when is_nil(wanted) or wanted == model, do: {:ok, model}

  def select_model(client, project, runtime, wanted) do
    with {:ok, catalog} <- MachineCache.catalog(client) do
      models = Catalog.models_for(catalog, runtime)

      selected =
        wanted ||
          if(runtime == project.runtime,
            do: project.model,
            else: Catalog.default_model(catalog, runtime)
          )

      if is_binary(selected) and selected in models,
        do: {:ok, selected},
        else:
          {:error,
           {:unprocessable, "invalid_model",
            "Choose one of #{AgentName.label(runtime)}'s models."}}
    end
  end

  defp nonblank(value) when is_binary(value) and value != "", do: value
  defp nonblank(_), do: nil
end

defmodule Ravix.Tracks.Runtime do
  @moduledoc "Thread choices after the caller has admitted project or track access."
  alias Ravix.Accounts.Inference
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.MachineCache
  alias Ravix.Projects.RuntimeAgents

  def options(user, project, client, last_runtime \\ nil, machine \\ :discover) do
    with {:ok, machine} <- options_machine(client, project, machine),
         {:ok, home} <- RuntimeAgents.home_runtime(project, client, machine && machine.sandbox_id),
         {:ok, usable} <- Inference.usable_agents(RuntimeAgents.owner(project)),
         {:ok, catalog} <- MachineCache.catalog(client) do
      runtimes =
        Enum.filter(["claude", "codex"], fn runtime ->
          runtime == home or Ravix.Config.dedicated_opens_enabled?(user)
        end)
        |> Enum.map(fn runtime ->
          %{
            runtime: runtime,
            connected: runtime in Enum.map(usable, &to_string/1),
            models: Catalog.models_for(catalog, runtime)
          }
        end)

      default = last_runtime || project.runtime

      default =
        if Enum.any?(runtimes, &(&1.runtime == default)), do: default, else: home

      {:ok, %{runtimes: runtimes, runtime: default, model: project.model}}
    end
  end

  defp options_machine(client, project, :discover), do: MachineCache.machine_of(client, project)
  defp options_machine(_client, _project, machine), do: {:ok, machine}

  def select(user, project, client, attrs, last_runtime \\ nil, sandbox_id \\ nil) do
    runtime = nonblank(attrs["runtime"]) || last_runtime || project.runtime
    model = nonblank(attrs["model"])

    with {:ok, home} <- RuntimeAgents.home_runtime(project, client, sandbox_id),
         :ok <- gate(user, %{project | runtime: home}, runtime),
         {:ok, true} <- Inference.usable?(RuntimeAgents.owner(project), runtime, fresh: true),
         {:ok, selected_model} <- select_model(client, project, runtime, model),
         {:ok, agent_id} <- RuntimeAgents.ensure(project, client, runtime, selected_model) do
      {:ok, %{runtime: runtime, model: selected_model, agent_id: agent_id, home: home}}
    else
      {:ok, false} ->
        {:error,
         {:conflict, "agent_not_connected", "The project owner has not connected this runtime."}}

      error ->
        error
    end
  end

  defdelegate pin_shared_home(project, selection, machine), to: RuntimeAgents

  def gate(user, project, runtime) do
    cond do
      runtime not in ["claude", "codex"] ->
        {:error, {:unprocessable, "invalid_runtime", "Choose Claude or Codex."}}

      runtime == project.runtime or Ravix.Config.dedicated_opens_enabled?(user) ->
        :ok

      true ->
        {:error,
         {:conflict, "guest_runtime_disabled",
          "Other-runtime threads are not enabled for your account yet."}}
    end
  end

  def select_model(_client, %{runtime: runtime, model: model}, runtime, wanted)
      when is_nil(wanted) or wanted == model, do: {:ok, model}

  def select_model(client, project, runtime, wanted) do
    with {:ok, catalog} <- MachineCache.catalog(client) do
      models = Catalog.models_for(catalog, runtime)

      selected =
        wanted || if(runtime == project.runtime, do: project.model, else: List.first(models))

      if is_binary(selected) and selected in models,
        do: {:ok, selected},
        else: {:error, {:unprocessable, "invalid_model", "Choose one of this runtime's models."}}
    end
  end

  defp nonblank(value) when is_binary(value) and value != "", do: value
  defp nonblank(_), do: nil
end

defmodule Ravix.Accounts.ThreadPreference do
  @moduledoc """
  A person's default for new threads, independent of the new-project default.

  Until explicitly chosen, use the most recently connected credential still held,
  across ChatGPT links, API keys and Claude tokens, and its first catalog model.
  Connection timestamps are recorded by Inference after successful writes. Legacy
  connections without timestamps use the recorded account agent, then catalog order;
  their historical connection order cannot be recovered from the credential list.
  Reads reload the person so another tab's explicit choice takes effect immediately.
  """
  import Ecto.Changeset
  alias Ravix.Accounts.{Inference, Store, User}
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.{MachineCache, Repo}

  def get(%User{} = person, catalog) do
    with {:ok, preference} <- candidate(person) do
      {:ok,
       if(preference,
         do: %{
           preference
           | model: valid_or_default(catalog, preference.runtime, preference.model)
         }
       )}
    end
  end

  @doc "The stored or derived runtime, before reading the catalog for its default model."
  def candidate(%User{} = person) do
    user = Store.get_user(person.id)

    case user do
      %User{preferred_runtime: runtime, preferred_model: model} when not is_nil(runtime) ->
        runtime = Atom.to_string(runtime)
        {:ok, %{runtime: runtime, model: model}}

      %User{} ->
        initial(user)

      nil ->
        {:error, :not_found}
    end
  end

  defp initial(%User{credential_connected_at: times, agent: nil})
       when map_size(times) == 0, do: {:ok, nil}

  defp initial(%User{credential_set_id: nil}), do: {:ok, nil}

  defp initial(user) do
    with {:ok, held} <- Inference.cached_held(user) do
      choice =
        Enum.max_by(
          held,
          fn {runtime, kind} ->
            {Map.get(user.credential_connected_at, "#{runtime}:#{kind}", ""),
             runtime == user.agent}
          end,
          fn -> nil end
        )

      case choice do
        {runtime, _kind} ->
          runtime = Atom.to_string(runtime)
          {:ok, %{runtime: runtime, model: nil}}

        nil ->
          {:ok, nil}
      end
    end
  end

  def options(%User{} = person, held) do
    user = Store.get_user(person.id)

    connected = Enum.map(held, fn {agent, _} -> to_string(agent) end)

    with %User{} <- user,
         {:ok, client} <- Ravix.Providers.fountain(),
         {:ok, catalog} <- MachineCache.catalog(client),
         {:ok, preference} <- get(user, catalog) do
      choices =
        for runtime <- ["claude", "codex"],
            runtime in connected,
            model <- Catalog.models_for(catalog, runtime),
            do: %{runtime: runtime, model: model}

      {:ok, %{choices: choices, preference: preference}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # No target-user id is accepted: all writes belong to the authenticated person.
  # Project picks may use the payer's connection even if this person holds none.
  def validate(runtime, model, catalog) do
    if runtime in ["claude", "codex"] and model in Catalog.models_for(catalog, runtime),
      do: :ok,
      else: {:error, {:unprocessable, "invalid_model", "Choose an available agent and model."}}
  end

  def put(%User{} = person, runtime, model, catalog) do
    with :ok <- validate(runtime, model, catalog),
         %User{} = user <- Store.get_user(person.id) do
      user
      |> cast(%{preferred_runtime: runtime, preferred_model: model}, [
        :preferred_runtime,
        :preferred_model
      ])
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def save(%User{} = user, runtime, model) do
    with {:ok, true} <- Inference.usable?(user, runtime, fresh: true),
         {:ok, client} <- Ravix.Providers.fountain(),
         {:ok, catalog} <- MachineCache.catalog(client) do
      put(user, runtime, model, catalog)
    else
      {:ok, false} ->
        {:error, {:unprocessable, "agent_not_connected", "Connect this agent first."}}

      error ->
        error
    end
  end

  def remember(user, runtime, model, client) do
    with {:ok, catalog} <- MachineCache.catalog(client),
         {:ok, _} <- put(user, runtime, model, catalog),
         do: :ok
  end

  defp valid_or_default(catalog, runtime, model) do
    models = Catalog.models_for(catalog, runtime)
    if model in models, do: model, else: List.first(models)
  end
end

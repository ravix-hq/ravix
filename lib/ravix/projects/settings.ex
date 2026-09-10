defmodule Ravix.Projects.Settings do
  @moduledoc """
  What a project's settings panel edits. Every field is a mutation in place.

  The panel shows the harness (runtime and model, against Fountain's
  catalog), the name, the setup script and packages of the environment, the
  *names* of the secrets in the environment and the vault (values are
  write-only), and the person's extra instructions. Saving is a series of
  independent mutations, each on the record that owns it, and the settings
  revision is bumped only for the ones Fountain injects at session start.
  """

  alias Ravix.Fountain
  alias Ravix.Projects
  alias Ravix.Projects.Project

  @typedoc "`ProjectSettings` from `shared/api.ts`."
  @type t :: %{
          name: String.t(),
          setup_script: String.t(),
          packages: %{optional(String.t()) => [String.t()]},
          env_keys: [String.t()],
          vault_keys: [String.t()],
          runtime: String.t(),
          catalog: map() | nil,
          model: String.t(),
          instructions: String.t()
        }

  @secret_key ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  The settings, read live from the environment, the two secret stores and
  the catalog. The environment read has to succeed; the rest degrade to
  empty lists and a nil catalog, since a panel with no catalog is still a
  panel.
  """
  @spec read(Project.t(), Fountain.Client.t()) :: {:ok, t()} | {:error, term()}
  def read(%Project{} = project, client) do
    with {:ok, env} <-
           Projects.fountain_result(Fountain.get_environment(client, project.environment_id)) do
      {:ok,
       %{
         runtime: project.runtime,
         catalog: Projects.Machine.catalog_or_nil(client),
         name: project.name,
         setup_script: env["setup_script"] || "",
         packages: if(is_map(env["packages"]), do: env["packages"], else: %{}),
         env_keys: keys_of(client, :environments, project.environment_id),
         # The clone token is Ravix's own plumbing, not one of the person's
         # secrets. Listing it invites somebody to delete it and then wonder
         # why their private repository stopped cloning.
         vault_keys:
           if(project.vault_id,
             do:
               Enum.reject(
                 keys_of(client, :vaults, project.vault_id),
                 &(&1 == Projects.clone_secret_key())
               ),
             else: []
           ),
         model: project.model,
         instructions: project.instructions || ""
       }}
    end
  end

  @doc """
  Apply a settings change and answer the resulting revision.

  `attrs` (string or atom keys), each optional: `runtime` and `model`
  (validated together against the catalog, then set on the agent), `name`,
  `setup_script` and `packages` (the environment), `instructions` (the
  agent's system prompt), and `secret` as `%{store: "vault" | "env", key,
  value}` where an empty value deletes. The harness, the instructions and a
  secret bump the revision; a name, a setup script or a package list does
  not, because Fountain applies those when the disk is built rather than
  when a session starts.

  Mutations are applied in that order and the first failure stops the rest;
  what was already saved stays saved, as it did in the TypeScript.
  """
  @spec update(Project.t(), map(), Fountain.Client.t()) :: {:ok, integer()} | {:error, term()}
  def update(%Project{} = project, attrs, client) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, bumps} <- harness(project, attrs, client),
         :ok <- rename(project, attrs),
         :ok <- environment(project, attrs, client),
         {:ok, bumps} <- instructions(project, attrs, client, bumps),
         {:ok, bumps} <- secret(project, attrs, client, bumps) do
      {:ok, if(bumps, do: Projects.Store.bump_rev(project.id), else: project.rev)}
    end
  end

  # ── each mutation ─────────────────────────────────────────────────────

  defp harness(project, attrs, client) do
    runtime = Map.get(attrs, "runtime", project.runtime)
    model = Map.get(attrs, "model", project.model)

    if runtime == project.runtime and model == project.model do
      {:ok, false}
    else
      with {:ok, catalog} <- Projects.fountain_result(Fountain.catalog(client)),
           :ok <- validate_harness(catalog, runtime, model),
           {:ok, _agent} <-
             Projects.fountain_result(
               Fountain.update_agent(client, project.agent_id, %{runtime: runtime, model: model})
             ) do
        Projects.Store.set_harness(project.id, runtime, model)
        {:ok, true}
      end
    end
  end

  defp validate_harness(catalog, runtime, model) when is_binary(runtime) and is_binary(model) do
    runtimes = List.wrap(catalog["runtimes"])
    models = List.wrap(get_in(catalog, ["models", runtime]))

    if runtime in runtimes and model in models,
      do: :ok,
      else: invalid_model()
  end

  defp validate_harness(_catalog, _runtime, _model), do: invalid_model()

  defp invalid_model,
    do:
      {:error,
       {:unprocessable, "invalid_model", "Choose an available harness and one of its models."}}

  defp rename(project, attrs) do
    case Map.get(attrs, "name") do
      name when is_binary(name) ->
        case name |> str(120) |> String.trim() do
          "" -> :ok
          trimmed -> Projects.Store.rename(project.id, trimmed)
        end

      _ ->
        :ok
    end
  end

  defp environment(project, attrs, client) do
    patch =
      %{}
      |> put_if(:setup_script, is_binary(attrs["setup_script"]), fn ->
        str(attrs["setup_script"], 20_000)
      end)
      |> put_if(:packages, Map.has_key?(attrs, "packages"), fn ->
        normalize_packages(attrs["packages"])
      end)

    if patch == %{} do
      :ok
    else
      with {:ok, _env} <-
             Projects.fountain_result(
               Fountain.update_environment(client, project.environment_id, patch)
             ) do
        :ok
      end
    end
  end

  defp instructions(project, attrs, client, bumps) do
    case Map.get(attrs, "instructions") do
      text when is_binary(text) ->
        text = str(text, 20_000)

        # Fountain first, then the row -- the same order as `harness/3` above.
        # Saved-but-not-pushed is the one state with no signal for it: the
        # panel reads the new text back from the row as though it took, while
        # the agent keeps running the old system prompt, and the `rev` bump
        # that would badge open tracks as stale never happens because this
        # failure stops it.
        with {:ok, _agent} <-
               Projects.fountain_result(
                 Fountain.update_agent(client, project.agent_id, %{
                   system: Projects.compose_system(%{project | instructions: text})
                 })
               ) do
          Projects.Store.set_instructions(project.id, text)
          {:ok, true}
        end

      _ ->
        {:ok, bumps}
    end
  end

  defp secret(project, attrs, client, bumps) do
    case Map.get(attrs, "secret") do
      %{} = raw ->
        raw = Map.new(raw, fn {k, v} -> {to_string(k), v} end)
        store = if raw["store"] == "vault", do: :vaults, else: :environments
        key = raw["key"] |> str(200) |> String.trim()
        target = if store == :vaults, do: project.vault_id, else: project.environment_id

        with :ok <- validate_key(key),
             :ok <- require_target(target),
             :ok <- write_secret(client, store, target, key, raw["value"]) do
          {:ok, true}
        end

      _ ->
        {:ok, bumps}
    end
  end

  defp validate_key(key) do
    cond do
      not Regex.match?(@secret_key, key) ->
        {:error, {:unprocessable, "bad_key", "A secret name is letters, digits and underscores."}}

      key == Projects.clone_secret_key() ->
        {:error,
         {:unprocessable, "reserved_key",
          "#{Projects.clone_secret_key()} is Ravix's own and is re-minted from GitHub."}}

      true ->
        :ok
    end
  end

  defp require_target(nil) do
    {:error,
     {:conflict, "no_vault",
      "This project has no vault, so it can only hold environment secrets."}}
  end

  defp require_target(_target), do: :ok

  defp write_secret(client, store, target, key, value) when is_binary(value) and value != "",
    do: Projects.fountain_result(Fountain.put_secret(client, store, target, key, value))

  defp write_secret(client, store, target, key, _value),
    do: Projects.fountain_result(Fountain.delete_secret(client, store, target, key))

  # ── shapes ────────────────────────────────────────────────────────────

  @doc """
  Packages, keyed by manager.

  Fountain rejects a flat array outright (`{"packages":["Invalid object.
  Got: array"]}`) and silently stores a manager it does not know, which
  reads as configured and installs nothing. So the shape is enforced here
  rather than trusted from the browser.
  """
  @spec normalize_packages(term()) :: %{optional(String.t()) => [String.t()]}
  def normalize_packages(raw) when is_map(raw) and not is_struct(raw) do
    Enum.reduce(raw, %{}, fn
      {manager, list}, acc when is_list(list) ->
        names =
          list
          |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
          |> Enum.map(&(&1 |> String.trim() |> String.slice(0, 120)))
          |> Enum.uniq()

        if names == [],
          do: acc,
          else: Map.put(acc, manager |> to_string() |> String.slice(0, 40), names)

      _other, acc ->
        acc
    end)
  end

  def normalize_packages(_raw), do: %{}

  # ── plumbing ──────────────────────────────────────────────────────────

  defp keys_of(client, store, id) do
    case Fountain.secret_keys(client, store, id) do
      {:ok, keys} -> Enum.map(keys, & &1["key"])
      _ -> []
    end
  end

  defp put_if(map, key, true, value), do: Map.put(map, key, value.())
  defp put_if(map, _key, false, _value), do: map

  defp str(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp str(_value, _max), do: ""
end

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

  @typedoc """
  What the panel is given to show. `@enforce_keys` covers all of it, so a
  field added here and forgotten in `read/2` raises where it is built.

  It was `ProjectSettings` from `shared/api.ts`, a bare map, which is also
  why `read/2` and the panel could disagree about whether `catalog` is ever
  absent as opposed to nil.
  """
  @enforce_keys [
    :name,
    :setup_script,
    :packages,
    :env_keys,
    :vault_keys,
    :runtime,
    :catalog,
    :model,
    :instructions
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
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

  @typedoc """
  What one save may change, and the only spelling past `update/3`.

  Every field is optional and *absence is the instruction*: a save that
  does not mention `instructions` leaves the system prompt alone, which is
  what lets the panel's several forms all arrive here. `Ecto.Changeset.cast/4`
  is what turns the browser's strings into this --- it is the thing in
  Elixir that takes params in whatever spelling the caller has and answers
  a definite atom-keyed map --- so nothing below it compares a string key
  or asks `Map.has_key?/2` about one.
  """
  @type change :: %{optional(atom()) => term()}

  @attrs %{
    name: :string,
    runtime: :string,
    model: :string,
    instructions: :string,
    setup_script: :string,
    packages: :map,
    secret: :map
  }

  @secret_attrs %{store: :string, key: :string, value: :string}

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
       %__MODULE__{
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
    with {:ok, change} <- cast_attrs(attrs),
         {:ok, bumps} <- harness(project, change, client),
         :ok <- rename(project, change),
         :ok <- environment(project, change, client),
         {:ok, bumps} <- instructions(project, change, client, bumps),
         {:ok, bumps} <- secret(project, change, client, bumps) do
      {:ok, if(bumps, do: Projects.Store.bump_rev(project.id), else: project.rev)}
    end
  end

  @doc """
  The changes a settings save is asking for, or a refusal naming the field.

  A field that is present but the wrong type --- `packages` as the array
  Fountain rejects outright, say --- is refused here rather than reaching a
  mutation that would have to decide what to do with it. A field that is
  absent is not mentioned in the answer, which is how "leave this alone"
  is said.
  """
  @spec cast_attrs(map()) :: {:ok, change()} | {:error, term()}
  def cast_attrs(attrs), do: attrs |> cast_into(@attrs) |> apply_cast("settings")

  defp cast_secret(raw), do: raw |> cast_into(@secret_attrs) |> apply_cast("secret")

  # `empty_values: []` because an empty string is a value here, not an
  # absence: clearing the harness box and saving is refused with "Choose an
  # available harness", which is the answer, and Ecto's default would have
  # turned it into "the caller said nothing about the harness" and kept the
  # old one silently.
  #
  # `nil` is still an absence, because `cast/4` reads it as no change from
  # the empty data map. Nothing a browser sends is nil --- a form sends
  # strings --- so that is a statement about callers inside Ravix, and the
  # statement is the useful one: `%{runtime: nil}` leaves the runtime alone.
  defp cast_into(params, types),
    do: Ecto.Changeset.cast({%{}, types}, params, Map.keys(types), empty_values: [])

  defp apply_cast(changeset, what) do
    case Ecto.Changeset.apply_action(changeset, :update) do
      {:ok, change} ->
        {:ok, change}

      {:error, %Ecto.Changeset{errors: errors}} ->
        field = errors |> List.first() |> elem(0)
        {:error, {:unprocessable, "bad_#{what}", "#{field} is not the right kind of value."}}
    end
  end

  # ── each mutation ─────────────────────────────────────────────────────

  defp harness(project, change, client) do
    runtime = Map.get(change, :runtime, project.runtime)
    model = Map.get(change, :model, project.model)

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

  defp rename(project, %{name: name}) do
    case name |> str(120) |> String.trim() do
      "" -> :ok
      trimmed -> Projects.Store.rename(project.id, trimmed)
    end
  end

  defp rename(_project, _change), do: :ok

  defp environment(project, change, client) do
    patch =
      %{}
      |> put_if(:setup_script, change, :setup_script, &str(&1, 20_000))
      |> put_if(:packages, change, :packages, &normalize_packages/1)

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

  defp instructions(project, change, client, bumps) do
    case change do
      %{instructions: raw} ->
        text = str(raw, 20_000)

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

  defp secret(project, %{secret: raw}, client, _bumps) do
    with {:ok, secret} <- cast_secret(raw) do
      store = if secret[:store] == "vault", do: :vaults, else: :environments
      key = secret |> Map.get(:key, "") |> str(200) |> String.trim()
      target = if store == :vaults, do: project.vault_id, else: project.environment_id

      with :ok <- validate_key(key),
           :ok <- require_target(target),
           :ok <- write_secret(client, store, target, key, Map.get(secret, :value)) do
        {:ok, true}
      end
    end
  end

  defp secret(_project, _change, _client, bumps), do: {:ok, bumps}

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

  # A field the caller did not mention is a field the environment keeps.
  defp put_if(patch, key, change, from, transform) when is_map_key(change, from),
    do: Map.put(patch, key, transform.(Map.fetch!(change, from)))

  defp put_if(patch, _key, _change, _from, _transform), do: patch

  defp str(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp str(_value, _max), do: ""
end

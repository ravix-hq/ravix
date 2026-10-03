defmodule Ravix.Projects.Settings do
  @moduledoc """
  What a project's settings panel edits.

  Runtime switches require an explicit rebuild; model edits stay in place.
  Investigated against Fountain a7b9dc6f (2026-09-26): Agents.update_agent
  changes the record, but Machines.Binding.attachable/5 refuses a machine
  whose runtime differs (`sandbox_runtime_mismatch`), in either direction.
  Codex's shared auth-file binding also survives conversation termination.
  Our mock previously accepted the mismatched attach and hid this failure.
  Switching therefore retires the agent/machine through Machine.rebuild/2,
  closing tracks and discarding the disk, before saving the new harness.
  A failed replacement leaves the old selection so the explicit switch can
  be retried (rebuild tolerates an already deleted agent).

  The panel shows the harness (runtime and model, against Fountain's
  catalog), the name, the setup script and packages of the environment, the
  *names* of the secrets in the environment and the vault (values are
  write-only), and the person's extra instructions. Saving is a series of
  independent mutations, each on the record that owns it, and the settings
  revision is bumped only for the ones Fountain injects at session start.
  """

  alias Ravix.Accounts.Inference
  alias Ravix.Fountain
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Projects
  alias Ravix.Projects.{EnvironmentVariables, Project, Store}

  @typedoc """
  What the panel is given to show. `@enforce_keys` covers all of it, so a
  field added here and forgotten in `read/2` raises where it is built.

  It was `ProjectSettings` from `shared/api.ts`, a bare map, which is also
  why `read/2` and the panel could disagree about whether `catalog` is ever
  absent as opposed to nil. They cannot now: it is a
  `Ravix.Fountain.Shapes.Catalog` and a Fountain that would not answer is
  an empty one, so the panel reads `catalog.runtimes` and finds a list.
  """
  @enforce_keys [
    :name,
    :setup_script,
    :packages,
    :env_vars,
    :env_keys,
    :vault_keys,
    :runtime,
    :catalog,
    :model,
    :instructions
  ]
  @derive {Inspect, except: [:env_vars]}
  defstruct @enforce_keys ++
              [
                secrets_pending: false,
                secrets_generation: 0,
                default_only: false,
                shared_tracks: nil
              ]

  @type t :: %__MODULE__{
          default_only: boolean(),
          shared_tracks: non_neg_integer() | nil,
          secrets_pending: boolean(),
          secrets_generation: non_neg_integer(),
          name: String.t(),
          setup_script: String.t(),
          packages: %{optional(String.t()) => [String.t()]},
          env_vars: %{optional(String.t()) => String.t()},
          env_keys: [String.t()],
          vault_keys: [String.t()],
          runtime: String.t(),
          catalog: Catalog.t(),
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
    runtime: :string,
    rebuild: :boolean,
    model: :string,
    instructions: :string,
    setup_script: :string,
    packages: :map,
    env_vars: :map,
    expected_env_vars: :map,
    secret: :map
  }

  @secret_attrs %{store: :string, key: :string, value: :string}

  @secret_key ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  The settings, read live from the environment, the two secret stores and
  the catalog. The environment read has to succeed; the rest degrade to
  empty lists and an empty catalog, since a panel with no catalog is still a
  panel.
  """
  @spec read(Project.t(), Fountain.Client.t()) :: {:ok, t()} | {:error, term()}
  def read(%Project{} = project, client) do
    with {:ok, env} <- Fountain.get_environment(client, project.environment_id) do
      {:ok,
       %__MODULE__{
         default_only: default_only?(project),
         shared_tracks:
           if(Project.maintenance?(project), do: Store.shared_track_count(project.id)),
         secrets_pending: project.secrets_pending,
         secrets_generation: project.secrets_generation,
         runtime: project.runtime,
         catalog: Projects.Machine.catalog(client),
         name: project.name,
         setup_script: env["setup_script"] || "",
         packages: if(is_map(env["packages"]), do: env["packages"], else: %{}),
         env_vars: env["env_vars"] || %{},
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

  `attrs` (string or atom keys), each optional: `rebuild: true` explicitly
  authorizes a runtime switch and disk replacement; `runtime` and `model`
  (validated together against the catalog, then set on the agent),
  `setup_script` and `packages` (the environment), `instructions` (the
  agent's system prompt), and `secret` as `%{store: "vault" | "env", key,
  value}` where an empty value deletes. The harness, the instructions and a
  secret or readable environment-variable change bumps the revision;
  a setup script or a package list does not, because Fountain applies those when the disk is built rather than
  when a session starts.

  The legacy `name` field is ignored; project names cannot be edited.

  The first failure stops remaining mutations. Successful session-start
  mutations still bump the revision when a later mutation fails.
  """
  @spec update(Project.t(), map(), Fountain.Client.t()) :: {:ok, integer()} | {:error, term()}
  def update(%Project{} = project, attrs, client) do
    with {:ok, change} <- cast_attrs(attrs),
         :ok <- validate_env_secrets(project, change, client),
         {:ok, project, bumps} <- harness(project, change, client) do
      steps = [
        &instructions(project, change, client, &1),
        &secret(project, change, client, &1),
        &environment(project, change, client, &1)
      ]

      {result, bumps} = Enum.reduce_while(steps, {:ok, bumps}, &apply_mutation/2)

      rev = if bumps, do: Projects.Store.bump_rev(project.id), else: project.rev
      if bumps and result != :ok, do: Ravix.Hub.publish(project.id, :settings)
      if result == :ok, do: {:ok, rev}, else: result
    end
  end

  defp apply_mutation(step, {:ok, bumps}) do
    case step.(bumps) do
      {:ok, next} -> {:cont, {:ok, next}}
      error -> {:halt, {error, bumps}}
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
  def cast_attrs(attrs) do
    key = if Map.has_key?(attrs, "env_vars"), do: "env_vars", else: :env_vars

    if Map.has_key?(attrs, key) do
      with {:ok, vars} <- EnvironmentVariables.normalize(Map.fetch!(attrs, key)),
           do: attrs |> Map.put(key, vars) |> cast_into(@attrs) |> apply_cast("settings")
    else
      attrs |> cast_into(@attrs) |> apply_cast("settings")
    end
  end

  defp validate_env_secrets(project, %{env_vars: vars}, client) do
    with {:ok, env_keys} <- Fountain.secret_keys(client, :environments, project.environment_id),
         {:ok, vault_keys} <- vault_secret_keys(project, client) do
      keys = Enum.map(env_keys ++ vault_keys, & &1["key"])

      if Enum.any?(Map.keys(vars), &(&1 in keys)),
        do:
          {:error,
           {:unprocessable, "env_secret_collision",
            "A variable cannot use an existing project secret name."}},
        else: :ok
    end
  end

  defp validate_env_secrets(_project, _change, _client), do: :ok

  defp vault_secret_keys(%{vault_id: nil}, _client), do: {:ok, []}

  defp vault_secret_keys(project, client),
    do: Fountain.secret_keys(client, :vaults, project.vault_id)

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
      {:ok, project, false}
    else
      with {:ok, catalog} <- Fountain.catalog(client),
           :ok <- validate_harness(catalog, runtime, model),
           :ok <- usable(project, runtime),
           {:ok, project} <- save_harness_mode(project, runtime, model, change, client) do
        {:ok, project, not Project.maintenance?(project)}
      end
    end
  end

  # ownership: Settings.update/3 is behind Access.project_of/2. Always read
  # the project's owner, never a teammate's choice or cached connectivity.
  defp usable(project, runtime) do
    owner = Ravix.Accounts.Store.get_user(project.user_id)

    case Inference.usable?(owner, runtime, fresh: true) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         {:conflict, "agent_not_connected",
          "Connect this agent in the project owner's account before selecting it."}}

      {:error, _} = error ->
        error
    end
  end

  def default_only?(project),
    do: Project.maintenance?(project) and Store.shared_track_count(project.id) == 0

  defp save_harness_mode(project, runtime, model, change, client) do
    if Project.maintenance?(project) do
      Ravix.Cluster.project_mutation(project.id, :shared_machine, fn ->
        save_defaults(project, runtime, model, change, client)
      end)
    else
      save_harness(project, runtime, model, change, client)
    end
  end

  defp save_defaults(project, runtime, model, change, client) do
    with :ok <- retire_for_defaults(project, runtime, change, client),
         :ok <- Store.set_defaults(project.id, runtime, model),
         do: {:ok, Store.get_project(project.id)}
  end

  defp retire_for_defaults(project, runtime, change, client) do
    cond do
      runtime == project.runtime and not project.shared_machine_retiring ->
        :ok

      default_only?(project) and not project.shared_machine_retiring ->
        :ok

      change[:rebuild] == true ->
        with {:ok, _} <- Projects.Deletion.retire_shared_locked(project, client), do: :ok

      true ->
        {:error,
         {:unprocessable, "rebuild_required",
          "Shared tracks still use the project machine. Choose Switch and rebuild; dedicated tracks are unaffected."}}
    end
  end

  defp save_harness(%{runtime: runtime} = project, runtime, model, _change, client) do
    with {:ok, _} <-
           Fountain.update_agent(client, project.agent_id, %{runtime: runtime, model: model}) do
      Projects.Store.set_harness(project.id, runtime, model)
      {:ok, %{project | model: model}}
    end
  end

  defp save_harness(project, runtime, model, %{rebuild: true}, client) do
    with {:ok, _} <- Projects.Machine.rebuild(%{project | runtime: runtime, model: model}, client) do
      Projects.Store.set_harness(project.id, runtime, model)
      {:ok, Projects.Store.get_project(project.id)}
    end
  end

  defp save_harness(_project, _runtime, _model, _change, _client) do
    {:error,
     {:unprocessable, "rebuild_required",
      "Switching agents closes every track and discards the machine's disk. Choose Switch and rebuild."}}
  end

  # Two refusals rather than one, because they are about two boxes. The
  # models offered depend on the runtime, so a runtime the catalog does not
  # know makes every model wrong and is the one to say; past that, the
  # runtime is fine and the model is not. One code for both said "choose an
  # available harness and one of its models" over a form with two inputs,
  # which is true and does not point anywhere.
  defp validate_harness(%Catalog{} = catalog, runtime, model)
       when is_binary(runtime) and is_binary(model) do
    cond do
      runtime not in ~w(claude codex) or runtime not in catalog.runtimes -> invalid_runtime()
      model not in Catalog.models_for(catalog, runtime) -> invalid_model()
      true -> :ok
    end
  end

  defp validate_harness(_catalog, runtime, _model) when not is_binary(runtime),
    do: invalid_runtime()

  defp validate_harness(_catalog, _runtime, _model), do: invalid_model()

  defp invalid_runtime,
    do: {:error, {:unprocessable, "invalid_runtime", "Choose an agent this deployment offers."}}

  defp invalid_model,
    do: {:error, {:unprocessable, "invalid_model", "Choose one of this agent's models."}}

  defp environment(project, change, client, bumps) do
    Ravix.Cluster.project_mutation(project.id, :env_vars_change, fn ->
      save_environment(project, change, client, bumps)
    end)
  end

  defp save_environment(project, change, client, bumps) do
    patch =
      %{}
      |> put_if(:setup_script, change, :setup_script, &str(&1, 20_000))
      |> put_if(:packages, change, :packages, &normalize_packages/1)
      |> put_if(:env_vars, change, :env_vars, &Function.identity/1)

    if patch == %{} do
      {:ok, bumps}
    else
      with {:ok, changed?} <- env_vars_changed(project, change, client),
           {:ok, _env} <- Fountain.update_environment(client, project.environment_id, patch) do
        # The track ribbon's "add a setup script" offer is read from the
        # memoised environment, so the answer this just changed has to be
        # dropped or the offer keeps appearing for another minute.
        Ravix.MachineCache.forget_environment(project.environment_id)
        {:ok, bumps or changed?}
      end
    end
  end

  defp env_vars_changed(project, %{env_vars: vars} = change, client) do
    with {:ok, env} <- Fountain.get_environment(client, project.environment_id) do
      current = env["env_vars"] || %{}

      if Map.has_key?(change, :expected_env_vars) and change.expected_env_vars != current do
        {:error,
         {:conflict, "env_vars_conflict",
          "Variables changed since you opened settings. Reload and try again."}}
      else
        {:ok, current != vars}
      end
    end
  end

  defp env_vars_changed(_project, _change, _client), do: {:ok, false}

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
               Fountain.update_agent(client, project.agent_id, %{
                 system: Projects.compose_system(%{project | instructions: text})
               }) do
          Projects.Store.set_instructions(project.id, text)
          {:ok, true}
        end

      _ ->
        {:ok, bumps}
    end
  end

  defp secret(project, %{secret: raw}, client, _bumps) do
    with {:ok, secret} <- cast_secret(raw), do: persist_secret(project, secret, client)
  end

  defp secret(_project, _change, _client, bumps), do: {:ok, bumps}

  defp persist_secret(project, secret, client) do
    store = if secret[:store] == "vault", do: :vaults, else: :environments
    key = secret |> Map.get(:key, "") |> str(200) |> String.trim()
    target = if store == :vaults, do: project.vault_id, else: project.environment_id

    with :ok <- validate_key(key), :ok <- require_target(target) do
      change_secret(project, client, store, target, key, Map.get(secret, :value))
    end
  end

  defp change_secret(project, client, store, target, key, value) do
    if Store.secret_snapshots?(project.id) do
      Ravix.Cluster.project_mutation(project.id, :secret_change, fn ->
        change_snapshot_secret(project, client, store, target, key, value)
      end)
    else
      secret_result(write_secret(client, store, target, key, value))
    end
  end

  defp change_snapshot_secret(project, client, store, target, key, value) do
    case Store.begin_secret_change(project.id) do
      {:ok, generation} ->
        result = write_secret(client, store, target, key, value)
        if confirmed_secret_write?(result), do: Store.finish_secret_change(project.id, generation)
        Ravix.Hub.publish(project.id, :tracks)
        secret_result(result)

      {:error, :secrets_pending} ->
        {:error,
         {:conflict, "secrets_pending",
          "A previous secret change is still awaiting confirmation. The project owner can confirm it has finished in Settings → Secrets before saving again."}}

      error ->
        error
    end
  end

  defp confirmed_secret_write?({:error, %Fountain.Error{} = error}),
    do: not Fountain.Error.unknown_outcome?(error)

  defp confirmed_secret_write?(:ok), do: true
  defp confirmed_secret_write?(_), do: false

  defp secret_result(:ok), do: {:ok, true}
  defp secret_result(error), do: error

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
    do: Fountain.put_secret(client, store, target, key, value)

  defp write_secret(client, store, target, key, _value),
    do: Fountain.delete_secret(client, store, target, key)

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

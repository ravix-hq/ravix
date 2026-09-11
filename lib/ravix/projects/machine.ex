defmodule Ravix.Projects.Machine do
  @moduledoc """
  The Fountain choreography behind a project: building the three records,
  retiring the agent for a rebuild, and taking everything back on a delete.

  Nothing about a machine is stored: a sandbox id in a row is a claim that
  goes stale the moment Fountain rebuilds anything, and a UI that confidently
  shows a box that died an hour ago is worse than one that says it does not
  know. `state/1` reads it live, through the memoised conversation list the
  track routes already keep warm.
  """

  alias Ravix.Fountain
  alias Ravix.Fountain.Error
  alias Ravix.Fountain.Shapes
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Fountain.Shapes.Conversation
  alias Ravix.Hub
  alias Ravix.Ids
  alias Ravix.Projects
  alias Ravix.Projects.MachineState
  alias Ravix.Projects.Project

  @typedoc "What a rebuild removed, and what would not go."
  @type rebuild_report :: %{
          removed: [String.t()],
          failed: [%{what: String.t(), why: String.t()}]
        }

  @typedoc "The three ids, plus the harness the agent was made with."
  @type provisioned :: %{
          environment_id: String.t(),
          vault_id: String.t() | nil,
          agent_id: String.t(),
          runtime: String.t(),
          model: String.t()
        }

  @default_runtime "claude"

  # Provider-prefixed, because Fountain's are.
  #
  # `POST /api/agents` validates `model` against `^[a-z0-9_-]+/[a-z0-9._-]+$`,
  # and the catalog lists `anthropic/claude-opus-5`. A bare `claude-opus-5`
  # survived here for a while only because `pick_runtime` falls through to
  # "whatever in the catalog has opus in the name", so the wrong constant was
  # invisible until the catalog call failed, at which point every project
  # creation would have 422'd on a field nobody was looking at.
  @default_model "anthropic/claude-opus-5"

  # ── creation ──────────────────────────────────────────────────────────

  @doc """
  The three records, in the only order that works.

  Takes the project as it will be inserted (name, repository, branch,
  installation) and returns the ids to insert it with. A half-made project
  is three orphaned Fountain records and a row that points at a machine
  nobody can build, so any failure unwinds what went in, in reverse, and
  reports the original failure rather than the cleanup's.
  """
  @spec provision(Project.t(), Fountain.Client.t()) :: {:ok, provisioned()} | {:error, term()}
  def provision(%Project{} = project, client) do
    state = %{environment_id: nil, vault_id: nil, agent_id: nil, runtime: nil, model: nil}

    Enum.reduce_while([&environment/3, &vault/3, &clone_token/3, &agent/3], {:ok, state}, fn
      step, {:ok, state} ->
        case step.(client, project, state) do
          {:ok, state} ->
            {:cont, {:ok, state}}

          {:error, reason} ->
            unwind(client, state)
            {:halt, {:error, reason}}
        end
    end)
  end

  defp environment(client, project, state) do
    repositories =
      if project.repo_full_name do
        [
          %{
            url: "https://github.com/#{project.repo_full_name}.git",
            mount_path: Ids.mount_path_for(project.repo_full_name),
            # Named on the repository whether or not it is private. A public
            # repo with a token attached still clones; a private one without
            # it fails at build time with an error a person cannot act on.
            secret_key: Projects.clone_secret_key()
          }
        ]
      else
        []
      end

    body = %{name: label(project), repositories: repositories, packages: %{}, setup_script: ""}

    with {:ok, env} <- Projects.fountain_result(Fountain.create_environment(client, body)) do
      {:ok, %{state | environment_id: env["id"]}}
    end
  end

  # Created up front even though nothing needs it yet, precisely because
  # attaching one later would change the identity and cost the disk.
  defp vault(client, project, state) do
    case Projects.fountain_result(Fountain.create_vault(client, %{name: label(project)})) do
      {:ok, vault} -> {:ok, %{state | vault_id: vault["id"]}}
      {:error, %Error{status: status}} when status in [403, 404, 501] -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  # The clone token, before the first machine is ever built. It expires in
  # an hour and is re-minted on every path that wakes the box (see
  # `refresh_clone_token/2`), but it has to be there for the *first* build too.
  defp clone_token(client, %Project{installation_id: id}, %{vault_id: vault_id} = state)
       when is_integer(id) and is_binary(vault_id) do
    with :ok <- refresh_clone_token(%{vault_id: vault_id, installation_id: id}, client) do
      {:ok, state}
    end
  end

  defp clone_token(_client, _project, state), do: {:ok, state}

  defp agent(client, project, state) do
    choice = pick_runtime(catalog(client))

    body =
      %{
        name: label(project),
        model: choice.model,
        runtime: choice.runtime,
        # The identity's own default, so every track on it gets the same home
        # without having to say so on each conversation.
        sandbox_mode: "persistent",
        description:
          if(project.repo_full_name,
            do: "The agent working on #{project.repo_full_name}.",
            else: "The agent on this Ravix project."
          ),
        system: Projects.compose_system(project),
        environment_id: state.environment_id,
        metadata: %{ravix: %{project: project.id}}
      }
      |> with_vault(state.vault_id)

    with {:ok, agent} <- Projects.fountain_result(Fountain.create_agent(client, body)) do
      {:ok, %{state | agent_id: agent["id"], runtime: choice.runtime, model: choice.model}}
    end
  end

  # ── the credential ────────────────────────────────────────────────────

  @doc """
  The clone token, re-minted.

  An installation token lives for an hour, and Fountain hands the vault to a
  sandbox when a *session* starts, so a project a person comes back to the
  next morning has a dead token in it, and the symptom is `git push` failing
  with "Authentication failed" in the middle of a turn. Every path that is
  about to make the machine talk to GitHub calls this first. Mint a fresh
  token for each preparation, and propagate failures so queued prompts can
  retry.
  """
  @spec refresh_clone_token(
          %{vault_id: String.t(), installation_id: integer()},
          Fountain.Client.t()
        ) ::
          :ok | {:error, term()}
  def refresh_clone_token(%{vault_id: vault_id, installation_id: installation_id}, client) do
    with {:ok, app} <- Projects.github(),
         {:ok, token} <-
           Projects.github_result(Ravix.GitHub.mint_clone_token(app, installation_id)) do
      Projects.fountain_result(
        Fountain.put_secret(client, :vaults, vault_id, Projects.clone_secret_key(), token)
      )
    end
  end

  @doc "Everything a project needs before its machine is woken."
  @spec prepare_machine(Project.t(), Fountain.Client.t()) :: :ok | {:error, term()}
  def prepare_machine(
        %Project{repo_full_name: repo, vault_id: vault_id, installation_id: installation_id},
        client
      )
      when is_binary(repo) and repo != "" and is_binary(vault_id) and is_integer(installation_id) do
    refresh_clone_token(%{vault_id: vault_id, installation_id: installation_id}, client)
  end

  def prepare_machine(%Project{}, _client), do: :ok

  # ── rebuild and destroy ───────────────────────────────────────────────

  @doc """
  A new machine, the same settings.

  Retiring the agent is the one removal that has to work: without it the
  next launch finds the same identity and the same box, and a "rebuild" that
  quietly did nothing is worse than one that says it failed. The live
  conversations are terminated first and their failures reported rather than
  fatal. Every open track is closed afterwards, through
  `Ravix.Tracks.close_all_for_rebuild/2`, and `tracks` is published.
  """
  @spec rebuild(Project.t(), Fountain.Client.t()) :: {:ok, rebuild_report()} | {:error, term()}
  def rebuild(%Project{} = project, client) do
    quiesce(project)

    with {:ok, conversations} <-
           Projects.fountain_result(Fountain.list_conversations(client, project.agent_id)),
         {removed, failed} = terminate_live(client, conversations),
         :ok <- delete_old_agent(client, project.agent_id),
         {:ok, agent} <- create_replacement(project, client) do
      # The agent id is the identity, so it is the one column that ever moves,
      # and when it moves, every track on the old disk is gone.
      Projects.Store.rebind_agent(project.id, agent["id"])
      Ravix.MachineCache.forget_project(project.id)
      Ravix.Tracks.close_all_for_rebuild(project, :rebuild)
      Hub.publish(project.id, :tracks)
      {:ok, %{removed: removed ++ ["agent"], failed: failed}}
    end
  end

  # A rebuild that got as far as deleting the agent and then failed to build
  # its replacement leaves `agent_id` naming something Fountain no longer has.
  # The retry has to be able to walk back over that step, so an agent that is
  # already gone is the outcome this wanted: without it the second attempt
  # stops on the 404 and the project can never be rebuilt again, only
  # destroyed.
  defp delete_old_agent(client, agent_id) do
    case Projects.fountain_result(Fountain.delete_agent(client, agent_id)) do
      {:error, %Error{status: 404}} -> :ok
      other -> other
    end
  end

  defp create_replacement(project, client) do
    choice = pick_runtime(catalog(client))

    body =
      %{
        name: label(project),
        model: blank_or(project.model, choice.model),
        runtime: blank_or(project.runtime, choice.runtime),
        sandbox_mode: "persistent",
        system: Projects.compose_system(project),
        environment_id: project.environment_id,
        metadata: %{ravix: %{project: project.id}}
      }
      |> with_vault(project.vault_id)

    Projects.fountain_result(Fountain.create_agent(client, body))
  end

  defp terminate_live(client, conversations) do
    conversations
    |> Enum.filter(&Shapes.live?/1)
    |> Enum.reduce({[], []}, fn conversation, {removed, failed} ->
      case Fountain.terminate(client, conversation.id) do
        :ok ->
          {removed ++ ["track"], failed}

        {:error, reason} ->
          {removed, failed ++ [%{what: "track #{conversation.id}", why: why(reason)}]}
      end
    end)
  end

  @doc "The machine, its settings and its secrets, gone; the row archived; `tracks` published."
  @spec destroy(Project.t(), Fountain.Client.t()) :: :ok
  def destroy(%Project{} = project, client) do
    quiesce(project)

    conversations =
      case Fountain.list_conversations(client, project.agent_id) do
        {:ok, list} -> list
        _ -> []
      end

    for conversation <- conversations, Shapes.live?(conversation) do
      Fountain.terminate(client, conversation.id)
    end

    unwind(client, project)
    Projects.Store.archive(project.id)
    Ravix.MachineCache.forget_project(project.id)
    Hub.publish(project.id, :tracks)
    :ok
  end

  # Nothing queued may reach a machine that is about to go, and no preview
  # may keep it awake: cancel every open track's prompts and retire the
  # project's previews before Fountain is touched.
  defp quiesce(project) do
    # ownership: `quiesce/1` runs behind `Access.project_of/2` on a rebuild or
    # a destroy; the machine these prompts were queued for is going away.
    Enum.each(
      Projects.Store.open_tracks(project.id),
      &Ravix.PromptQueue.Store.cancel_track(&1.id)
    )

    Ravix.Previews.retire_project(project.id)
  end

  @doc "Take back what went in, in reverse, ignoring what will not go."
  @spec unwind(Fountain.Client.t(), %{
          optional(:agent_id) => String.t() | nil,
          optional(:vault_id) => String.t() | nil,
          optional(:environment_id) => String.t() | nil,
          optional(atom()) => term()
        }) :: :ok
  def unwind(client, ids) do
    if agent_id = Map.get(ids, :agent_id), do: Fountain.delete_agent(client, agent_id)
    if vault_id = Map.get(ids, :vault_id), do: Fountain.delete_vault(client, vault_id)

    if environment_id = Map.get(ids, :environment_id),
      do: Fountain.delete_environment(client, environment_id)

    :ok
  end

  # ── the machine, read live ────────────────────────────────────────────

  @doc """
  A project's machine, from its conversations.

  One memoised, agent-narrowed list call answers for each project, through
  `Ravix.MachineCache.conversations/3`, and it is the same one the track
  routes make, so it is usually already in the memo. The newest conversation
  with a sandbox names the machine; it is `:ready` while that conversation is
  live and `:suspended` once it has ended. `sprite_name` is deliberately nil:
  the conversation list serves `"sandbox": null`, so the only honest answer
  here is "not read". The terminal asks `Ravix.Tracks.sprite_for/1` when it
  actually needs one. A list that cannot be read is no machine.
  """
  @spec state(Project.t()) :: Projects.machine()
  def state(%Project{} = project) do
    with {:ok, client} <- Projects.fountain(),
         {:ok, conversations} <- Ravix.MachineCache.conversations(client, project, []) do
      conversations
      |> Enum.filter(&is_binary(&1.sandbox_id))
      |> Shapes.newest()
      |> machine_from()
    else
      _ -> none()
    end
  end

  defp machine_from(nil), do: none()

  defp machine_from(%Conversation{} = conversation) do
    %MachineState{
      sandbox_id: conversation.sandbox_id,
      status: if(Shapes.live?(conversation), do: :ready, else: :suspended),
      sprite_name: nil
    }
  end

  @doc "No machine."
  @spec none() :: Projects.machine()
  def none, do: %MachineState{sandbox_id: nil, status: :none, sprite_name: nil}

  # ── small decisions ───────────────────────────────────────────────────

  @doc """
  The runtime and model, reconciled with what this Fountain actually has.

  Not a question the app asks. A form on first run is a form between
  somebody and the thing they came for, answered identically by everyone,
  and the project panel says what was picked and lets it be changed
  afterwards, which is where the decision belongs.

  Takes a `Ravix.Fountain.Shapes.Catalog`. A Fountain that could not be read
  arrives as `Ravix.Fountain.Shapes.Catalog.empty/0`, which decides the same
  way, so there is no second argument shape and no nil to test for.
  """
  @spec pick_runtime(Catalog.t()) :: %{runtime: String.t(), model: String.t()}
  def pick_runtime(%Catalog{runtimes: runtimes} = catalog) do
    runtime =
      cond do
        @default_runtime in runtimes -> @default_runtime
        runtimes != [] -> hd(runtimes)
        true -> @default_runtime
      end

    models = Catalog.models_for(catalog, runtime)

    model =
      cond do
        @default_model in models -> @default_model
        opus = Enum.find(models, &String.contains?(&1, "opus")) -> opus
        models != [] -> hd(models)
        true -> @default_model
      end

    %{runtime: runtime, model: model}
  end

  @doc """
  The catalog, empty when it could not be read: nothing here should fail on it.

  `Ravix.Fountain.Shapes.Catalog.empty/0` rather than nil because every
  caller --- `pick_runtime/1` and the settings panel's runtime list --- does
  the same thing with both, and a nil that is only ever turned back into an
  empty one is a nil two modules have to remember.
  """
  @spec catalog(Fountain.Client.t()) :: Catalog.t()
  def catalog(client) do
    case Fountain.catalog(client) do
      {:ok, %Catalog{} = catalog} -> catalog
      _ -> Catalog.empty()
    end
  end

  defp label(%Project{name: name}), do: "Ravix · #{name}"

  defp with_vault(body, nil), do: body
  defp with_vault(body, ""), do: body
  defp with_vault(body, vault_id), do: Map.put(body, :vault_id, vault_id)

  defp blank_or(nil, fallback), do: fallback
  defp blank_or("", fallback), do: fallback
  defp blank_or(value, _fallback), do: value

  defp why(%Error{message: message}), do: message
  defp why(:unconfigured), do: "Fountain is not configured"
end

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

  alias Ravix.Accounts.User
  alias Ravix.Fountain
  alias Ravix.Fountain.Error
  alias Ravix.Fountain.Shapes
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Fountain.Shapes.Conversation
  alias Ravix.Hub
  alias Ravix.Ids
  alias Ravix.Previews.Lifecycle
  alias Ravix.Projects
  alias Ravix.Projects.Machine.Harness
  alias Ravix.Projects.Machine.Provisioned
  alias Ravix.Projects.Machine.Rebuild
  alias Ravix.Projects.MachineState
  alias Ravix.Projects.Project

  @default_runtime "claude"

  # ── creation ──────────────────────────────────────────────────────────

  @doc """
  The three records, in the only order that works.

  Takes the project as it will be inserted (name, repository, branch,
  installation) and its owner, and returns the ids to insert it with. The
  caller supplies the resolved harness whose credential availability it checked.
  The owner supplies the credential set that pays for it (`Ravix.Accounts.Inference`),
  whoever goes on to work in the project. A half-made project
  is three orphaned Fountain records and a row that points at a machine
  nobody can build, so any failure unwinds what went in, in reverse, and
  reports the original failure rather than the cleanup's.
  """
  @spec provision(Project.t(), User.t(), Fountain.Client.t(), Harness.t()) ::
          {:ok, Provisioned.t()} | {:error, term()}
  def provision(%Project{} = project, %User{} = owner, client, %Harness{} = harness) do
    steps = [&environment/3, &vault/3, &clone_token/3, &create_agent(&1, &2, &3, harness, owner)]

    Enum.reduce_while(steps, {:ok, %Provisioned{}}, fn
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
    body = %{
      name: fountain_name(project),
      repositories: repositories(project),
      packages: %{},
      setup_script: ""
    }

    case Fountain.create_environment(client, body) do
      {:ok, env} -> {:ok, %{state | environment_id: env["id"]}}
      {:error, reason} -> {:error, name_taken(reason)}
    end
  end

  # What the environment clones: the project's repository, or nothing.
  defp repositories(%Project{repo_full_name: repo}) when is_binary(repo) and repo != "" do
    [
      %{
        url: "https://github.com/#{repo}.git",
        mount_path: Ids.mount_path_for(repo),
        # Named on the repository whether or not it is private. A public
        # repo with a token attached still clones; a private one without
        # it fails at build time with an error a person cannot act on.
        secret_key: Projects.clone_secret_key()
      }
    ]
  end

  defp repositories(%Project{}), do: []

  # Created up front even though nothing needs it yet, precisely because
  # attaching one later would change the identity and cost the disk.
  defp vault(client, project, state) do
    case Fountain.create_vault(client, %{name: fountain_name(project)}) do
      {:ok, vault} -> {:ok, %{state | vault_id: vault["id"]}}
      {:error, %Error{status: status}} when status in [403, 404, 501] -> {:ok, state}
      {:error, reason} -> {:error, name_taken(reason)}
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

  @doc "Resolve the requested runtime (or catalog default) before creation spends anything."
  @spec creation_harness(Fountain.Client.t(), String.t() | nil) ::
          {:ok, Harness.t()} | {:error, term()}
  def creation_harness(client, wanted), do: harness_for(catalog(client), wanted)

  # The project's chosen agent (or the owner's default), when Fountain runs it. A catalog that *lists*
  # runtimes and leaves theirs out is refused rather than quietly built on
  # another: the machine would come up on Claude Code with an OpenAI key to
  # spend, and say so only when the first turn failed. A catalog that could
  # not be read lists nothing and refuses nothing.
  defp harness_for(%Catalog{runtimes: runtimes} = catalog, wanted) do
    if is_binary(wanted) and runtimes != [] and wanted not in runtimes do
      {:error,
       {:conflict, "agent_unavailable",
        "This deployment's Fountain does not run the agent you chose. Choose the other one, or ask whoever runs this deployment."}}
    else
      {:ok, pick_runtime(catalog, wanted)}
    end
  end

  defp create_agent(client, project, state, choice, owner) do
    body =
      %{
        name: fountain_name(project),
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
      |> with_credentials(owner.credential_set_id)

    case Fountain.create_agent(client, body) do
      {:ok, agent} ->
        {:ok,
         %{
           state
           | agent_id: agent["id"],
             runtime: choice.runtime,
             model: choice.model,
             credential_set_id: owner.credential_set_id
         }}

      {:error, reason} ->
        {:error, name_taken(reason)}
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
    with {:ok, app} <- Ravix.Providers.github(),
         {:ok, token} <- Ravix.GitHub.mint_clone_token(app, installation_id) do
      Fountain.put_secret(client, :vaults, vault_id, Projects.clone_secret_key(), token)
    end
  end

  @doc "Everything a project needs before its machine is woken."
  @spec prepare_machine(Project.t(), Fountain.Client.t()) :: :ok | {:error, term()}
  def prepare_machine(%Project{} = project, client) do
    with :ok <- adopt_credentials(project, client), do: fresh_clone_token(project, client)
  end

  defp fresh_clone_token(
         %Project{repo_full_name: repo, vault_id: vault_id, installation_id: installation_id},
         client
       )
       when is_binary(repo) and repo != "" and is_binary(vault_id) and is_integer(installation_id) do
    refresh_clone_token(%{vault_id: vault_id, installation_id: installation_id}, client)
  end

  defp fresh_clone_token(%Project{}, _client), do: :ok

  @doc """
  Point the project's agent at its owner's credential set, when it is not
  already.

  A project made before its owner connected anything --- every project that
  predates `Ravix.Accounts.Inference`, and any made by somebody who skipped
  that step --- has an agent with no set, which runs on the deployment's
  default. Connecting afterwards has to reach those projects, and this is
  where it does: on the way to waking the machine, which every track opened
  and every queued prompt passes through, so it needs no job of its own and
  nothing to hand over when an instance leaves (ADR 0003). The row records
  which set the agent was last pointed at, so the usual answer is a
  comparison and no call.

  Changing it is safe for what is already running. Fountain binds a
  conversation to the source it started on, so open tracks carry on spending
  what they were spending and only new ones spend the owner's. An owner who
  has connected nothing is left exactly as they were.
  """
  @spec adopt_credentials(Project.t(), Fountain.Client.t()) :: :ok | {:error, term()}
  def adopt_credentials(%Project{credential_set_id: current} = project, client) do
    case owner_set(project) do
      nil ->
        :ok

      ^current ->
        :ok

      set_id ->
        Ravix.Cluster.agent_allowlist(project.agent_id, fn -> adopt(project, client, set_id) end)
    end
  end

  defp adopt(project, client, set_id) do
    with {:ok, body} <- adopted_body(project, client, set_id),
         {:ok, _agent} <- Fountain.update_agent(client, project.agent_id, body),
         do: Projects.Store.set_credential_set(project.id, set_id)
  end

  # The owner's set becomes the default. The allowlist is reset to `[]` only
  # while nothing on the project is creator-billed: a creator-billed track's
  # payer was admitted on this agent (`RuntimeAgents.admit_payer/3`), and
  # resetting the list would evict them. Then the list is read and kept, and
  # only an agent that never had one (nil, which Fountain reads as every set
  # on the account) is given one.
  defp adopted_body(project, client, set_id) do
    # ownership: the caller is through Access.project_of/2 or Access.project_access/2;
    # this asks only whether any open track on the project is creator-billed.
    if Ravix.Tracks.Store.creator_billed_open?(project.id) do
      with {:ok, agent} <- Fountain.get_agent(client, project.agent_id) do
        body = %{inference_credential_id: set_id}

        {:ok,
         if(is_list(agent["allowed_inference_credential_ids"]),
           do: body,
           else: Map.put(body, :allowed_inference_credential_ids, [])
         )}
      end
    else
      {:ok, with_credentials(%{}, set_id)}
    end
  end

  # ownership: the owner's row, read by the project's own `user_id`. The caller
  # is already through `Access.project_of/2` or `Access.project_access/2`, and
  # what is read is which set pays, which is the owner's whoever is asking.
  defp owner_set(%Project{user_id: user_id}) do
    case Ravix.Accounts.Store.get_user(user_id) do
      %User{credential_set_id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

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
  @spec rebuild(Project.t(), Fountain.Client.t()) :: {:ok, Rebuild.t()} | {:error, term()}
  def rebuild(%Project{} = project, client) do
    if Project.maintenance?(project),
      do: Projects.Deletion.retire_shared(project, client),
      else: with(:ok <- shared_lifecycle(project), do: rebuild_shared(project, client))
  end

  defp rebuild_shared(project, client) do
    quiesce(project)

    with {:ok, conversations} <- Fountain.list_conversations(client, project.agent_id),
         {removed, failed} = terminate_live(client, conversations),
         :ok <- Projects.RuntimeAgents.retire(project, client),
         :ok <- delete_old_agent(client, project.agent_id),
         set_id = owner_set(project),
         {:ok, agent} <- create_replacement(project, set_id, client) do
      # The agent id is the identity, so it is the one column that ever moves,
      # and when it moves, every track on the old disk is gone. What pays for
      # it moves with it: the new agent was built on the owner's set as it is
      # today.
      Projects.Store.rebind_agent(project.id, agent["id"], set_id, project.runtime)
      Ravix.MachineCache.forget_project(project.id)
      Ravix.Tracks.close_all_for_rebuild(project, :rebuild)
      Hub.publish(project.id, :tracks)
      {:ok, %Rebuild{removed: removed ++ ["agent"], failed: failed}}
    end
  end

  # A rebuild that got as far as deleting the agent and then failed to build
  # its replacement leaves `agent_id` naming something Fountain no longer has.
  # The retry has to be able to walk back over that step, so an agent that is
  # already gone is the outcome this wanted: without it the second attempt
  # stops on the 404 and the project can never be rebuilt again, only
  # destroyed.
  defp delete_old_agent(client, agent_id) do
    case Fountain.delete_agent(client, agent_id) do
      {:error, %Error{status: 404}} -> :ok
      other -> other
    end
  end

  defp create_replacement(project, set_id, client) do
    choice = pick_runtime(catalog(client))

    body =
      %{
        name: fountain_name(project),
        model: blank_or(project.model, choice.model),
        runtime: blank_or(project.runtime, choice.runtime),
        sandbox_mode: "persistent",
        system: Projects.compose_system(project),
        environment_id: project.environment_id,
        metadata: %{ravix: %{project: project.id}}
      }
      |> with_vault(project.vault_id)
      |> with_credentials(set_id)

    with {:error, reason} <- Fountain.create_agent(client, body), do: {:error, name_taken(reason)}
  end

  defp terminate_live(client, conversations) do
    conversations
    |> Enum.filter(&Shapes.live?/1)
    |> Enum.reduce({[], []}, fn conversation, {removed, failed} ->
      case Fountain.terminate(client, conversation.id) do
        :ok ->
          {removed ++ ["track"], failed}

        {:error, reason} ->
          failure = %Rebuild.Failure{what: "track #{conversation.id}", why: why(reason)}
          {removed, failed ++ [failure]}
      end
    end)
  end

  @doc """
  The project on another repository, and a machine built from it (RAV-76).

  The caller owns the project and has checked the App reads `target.repo`.
  In order:

    1. A project whose rebuild would be refused is refused first: dedicated
       tracks are on machines of their own, cloned from the old repository,
       which a project rebuild does not replace.
    2. The row, so a repository the workspace already has a project for is
       refused before Fountain is touched.
    3. The environment's clone, changed in place: the setup script,
       packages, variables and secrets stay, and so does the vault. When
       Fountain refuses, the row is put back.
    4. The rebuild, which closes every track. On a shared machine that is
       `rebuild/2`, whose new agent's system prompt names the new clone; on
       the maintenance path the shared machine is retired and the agents'
       system prompts are rewritten.

  A failure at step 4 is `{:error, {:not_rebuilt, reason}}`: the repository
  has changed, and rebuilding from the Danger zone finishes the job.
  Publishes `settings` once the repository has changed.
  """
  @spec change_repository(
          Project.t(),
          %{
            repo: Ravix.GitHub.Shapes.RepoRef.t(),
            installation_id: integer(),
            workspace_installation_id: String.t() | nil
          },
          Fountain.Client.t()
        ) :: {:ok, Rebuild.t()} | {:error, term()}
  def change_repository(%Project{} = project, target, client) do
    with :ok <- change_ready(project),
         {:ok, changed} <- repoint_row(project, target),
         :ok <- repoint_environment(project, changed, client) do
      Hub.publish(project.id, :settings)

      case rebuild_on(changed, client) do
        {:ok, outcome} -> {:ok, outcome}
        {:error, reason} -> {:error, {:not_rebuilt, reason}}
      end
    end
  end

  defp change_ready(project) do
    if Project.maintenance?(project) do
      # ownership: `Projects.change_repository/3` admitted the owner through
      # `Access.project_of/2`; this asks only whether any open track has a
      # machine of its own.
      if Enum.any?(Ravix.Tracks.Store.tracks_of(project.id), &(&1.sandbox_layout == :dedicated)),
        do:
          {:error,
           {:conflict, "dedicated_tracks_open",
            "Close this project's tracks with their own machines first: they were cloned from the current repository."}},
        else: :ok
    else
      shared_lifecycle(project)
    end
  end

  defp repoint_row(project, %{repo: repo} = target) do
    fields =
      %{
        repo_full_name: repo.full_name,
        repo_private: repo.private == true,
        default_branch: repo.default_branch,
        installation_id: target.installation_id,
        github_repo_id: repo.id
      }
      |> then(fn fields ->
        if target.workspace_installation_id,
          do: Map.put(fields, :workspace_installation_id, target.workspace_installation_id),
          else: fields
      end)

    case Projects.Store.change_repository(project.id, fields) do
      {:ok, changed} ->
        {:ok, changed}

      {:error, :taken} ->
        {:error,
         {:conflict, "repository_taken",
          "This workspace already has a project for #{repo.full_name}."}}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp repoint_environment(project, changed, client) do
    case Fountain.update_environment(client, project.environment_id, %{
           repositories: repositories(changed)
         }) do
      {:ok, _env} ->
        Ravix.MachineCache.forget_environment(project.environment_id)
        :ok

      {:error, reason} ->
        _ =
          Projects.Store.change_repository(
            project.id,
            Map.take(
              project,
              ~w(repo_full_name repo_private default_branch installation_id github_repo_id workspace_installation_id)a
            )
          )

        {:error, reason}
    end
  end

  defp rebuild_on(changed, client) do
    if Project.maintenance?(changed) do
      with {:ok, outcome} <- Projects.Deletion.retire_shared(changed, client),
           :ok <- rewrite_prompts(changed, client),
           do: {:ok, outcome}
    else
      rebuild(changed, client)
    end
  end

  # The agents stay on the maintenance path, so their system prompts, which
  # name the clone, are told about the new one.
  defp rewrite_prompts(project, client) do
    system = Projects.compose_system(project)
    runtime_agents = for %{agent_id: id} <- Projects.Store.runtime_agents(project.id), id, do: id

    Enum.reduce_while([project.agent_id | runtime_agents], :ok, fn agent_id, :ok ->
      case Fountain.update_agent(client, agent_id, %{system: system}) do
        {:ok, _agent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "The machine, its settings and its secrets, gone; the row archived; `tracks` published."
  @spec destroy(Project.t(), Fountain.Client.t()) :: :ok | {:error, term()}
  def destroy(%Project{} = project, client) do
    if Project.maintenance?(project),
      do: Projects.Deletion.request(project),
      else: with(:ok <- shared_lifecycle(project), do: destroy_shared(project, client))
  end

  defp destroy_shared(project, client) do
    quiesce(project)

    conversations =
      case Fountain.list_conversations(client, project.agent_id) do
        {:ok, list} -> list
        _ -> []
      end

    for conversation <- conversations, Shapes.live?(conversation) do
      Fountain.terminate(client, conversation.id)
    end

    with :ok <- Projects.RuntimeAgents.retire(project, client) do
      unwind(client, project)
      Projects.Store.archive(project.id)
      Ravix.MachineCache.forget_project(project.id)
      Hub.publish(project.id, :tracks)
      :ok
    end
  end

  # Deleting the home agent also deletes dedicated sandboxes. B8 replaces
  # this legacy maintenance path; until then refuse before touching providers.
  defp shared_lifecycle(project) do
    # ownership: rebuild/destroy are behind Access.project_of; closed tracks
    # can still have cleanup pending, so include them when protecting ownership.
    if Enum.any?(
         Ravix.Tracks.Store.tracks_of(project.id, :all),
         &(&1.sandbox_layout == :dedicated)
       ) do
      {:error,
       {:conflict, "dedicated_lifecycle_pending",
        "This project has dedicated workspaces. Project-wide rebuild and deletion are not available yet."}}
    else
      :ok
    end
  end

  # Nothing queued may reach a machine that is about to go, and no preview
  # may keep it awake: cancel every open track's prompts and retire the
  # project's previews before Fountain is touched.
  defp quiesce(project) do
    # ownership: `quiesce/1` runs behind `Access.project_of/2` on a rebuild or
    # a destroy; the machine these prompts were queued for is going away.
    Enum.each(
      Enum.filter(Projects.Store.open_tracks(project.id), &(&1.sandbox_layout == :shared)),
      &Ravix.PromptQueue.Store.cancel_track(&1.id)
    )

    # ownership: the same `Access.project_of/2` door; every preview on the
    # project is retired with the machine its services were defined on.
    Lifecycle.retire_project(project.id)
  end

  @doc """
  Take back what went in, in reverse, ignoring what will not go.

  Two shapes, because there are two reasons to do this: a creation that
  failed part way and has a `Ravix.Projects.Machine.Provisioned` holding
  whatever went in, and a project being destroyed, which has its own three
  columns. The order matters and is the same either way --- the agent names
  the identity, so it goes first.
  """
  @spec unwind(Fountain.Client.t(), Provisioned.t() | Project.t()) :: :ok
  def unwind(client, %Provisioned{} = ids),
    do: delete_records(client, ids.agent_id, ids.vault_id, ids.environment_id)

  def unwind(client, %Project{} = project),
    do: delete_records(client, project.agent_id, project.vault_id, project.environment_id)

  defp delete_records(client, agent_id, vault_id, environment_id) do
    if agent_id, do: Fountain.delete_agent(client, agent_id)
    if vault_id, do: Fountain.delete_vault(client, vault_id)
    if environment_id, do: Fountain.delete_environment(client, environment_id)
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
    with {:ok, client} <- Ravix.Providers.fountain(),
         {:ok, conversations} <- Ravix.MachineCache.conversations(client, project, []) do
      conversations
      |> Ravix.MachineCache.shared_only(project)
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
  @spec pick_runtime(Catalog.t(), String.t() | nil) :: Harness.t()
  def pick_runtime(%Catalog{runtimes: runtimes} = catalog, wanted \\ nil) do
    runtime = runtime_from(runtimes, wanted)
    %Harness{runtime: runtime, model: Catalog.default_model(catalog, runtime)}
  end

  # `wanted` is the agent the owner chose at sign-up, which is the one question
  # the paragraph above does let the app ask: it decides whose subscription is
  # spent, so it cannot be answered identically by everyone. A catalog that
  # lists nothing could not be read, and does not overrule them.
  defp runtime_from(runtimes, wanted) when is_binary(wanted) do
    if wanted in runtimes or runtimes == [], do: wanted, else: runtime_from(runtimes, nil)
  end

  defp runtime_from(runtimes, nil) do
    cond do
      @default_runtime in runtimes -> @default_runtime
      runtimes != [] -> hd(runtimes)
      true -> @default_runtime
    end
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

  @doc """
  The name every Fountain record made for a project is filed under.

  Every Ravix person shares one Fountain user, and Fountain keeps
  environment, vault and agent names unique per user, so a display name alone
  would let the first project called "api" claim it for everybody. The first
  eight characters of the project id make it the project's own. A runtime
  agent (`Ravix.Projects.RuntimeAgents`) adds its runtime, as it shares the
  project's environment.

  Records made before this naming keep the name they were created with:
  nothing here looks a record up by name, only by the id the row stores.
  """
  @spec fountain_name(Project.t(), String.t() | nil) :: String.t()
  def fountain_name(%Project{id: id, name: name}, suffix \\ nil) do
    Enum.join(["Ravix", name, String.slice(id, 0, 8)] ++ List.wrap(suffix), " · ")
  end

  @doc """
  Fountain refusing a record because its name is taken, as a tagged conflict.

  The short id makes this unlikely, not impossible (a record left behind
  under the same name, or two ids sharing a prefix), and a person should be
  told to retry rather than shown a generic provider failure. Anything else
  passes through unchanged.
  """
  @spec name_taken(term()) :: term()
  def name_taken(%Error{} = error) do
    if Error.name_taken?(error),
      do:
        {:conflict, "fountain_name_taken",
         "The machine service already has a record with this project's name. Try again, or choose a different name."},
      else: error
  end

  def name_taken(reason), do: reason

  defp with_vault(body, nil), do: body
  defp with_vault(body, ""), do: body
  defp with_vault(body, vault_id), do: Map.put(body, :vault_id, vault_id)

  # `[]` rather than leaving the allowlist open: no launch may name a
  # different set, so nothing can move a project's spending off its owner.
  defp with_credentials(body, nil), do: body

  defp with_credentials(body, set_id) do
    body
    |> Map.put(:inference_credential_id, set_id)
    |> Map.put(:allowed_inference_credential_ids, [])
  end

  defp blank_or(nil, fallback), do: fallback
  defp blank_or("", fallback), do: fallback
  defp blank_or(value, _fallback), do: value

  defp why(%Error{message: message}), do: message
  defp why({:unconfigured, :fountain}), do: "Fountain is not configured"
end

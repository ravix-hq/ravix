defmodule Ravix.Projects do
  @moduledoc """
  Projects, which are machines.

  Creation checks the catalog and the owner's credentials before making
  Fountain records in a fixed order. Sandbox identity is `(user, agent, environment, vault)` *by
  id*, so the environment and the vault must exist before the agent, because
  the agent is created already pointing at them. An agent updated afterwards
  to point at them would be an agent whose identity changed between its
  creation and its first machine, and a changed identity is a lost disk.

  After that, nothing here ever replaces one of those three records. Every
  setting the project panel offers is a mutation in place. That is the same
  decision paddock made and for the same reason: the machine is the thing
  people care about, and no configuration change should be able to take it.

  The credential is the part ravix does differently, because it has a
  GitHub App and paddock deliberately does not. A private repository is
  cloned with an **installation token**, scoped to the repositories that
  person chose and expiring in an hour, written into the project's *vault*
  under `GITHUB_TOKEN`. Fountain's egress broker keeps a two-entry catalog
  of exactly `GITHUB_TOKEN` and `GH_TOKEN` and attaches git's
  `x-access-token` basic auth in flight, so the machine holds a placeholder
  and never the token itself. That is worth the whole GitHub App on its own:
  the alternative is a personal token, scoped to everything you can reach,
  sitting in an env var that any agent turn can print.

  This module is the port of `server/projects.ts`, the `repos` and `refs`
  routes of `server/repos.ts`, and the project half of `server/db.ts`. The
  Fountain choreography (create, rebuild, destroy) lives in
  `Ravix.Projects.Machine`; the settings surface in `Ravix.Projects.Settings`.
  Every route-shaped function takes the `%Ravix.Accounts.User{}` first and
  answers `{:ok, value} | {:error, reason}`, where `reason` is one of
  `:not_found`, `{:not_found, code, message}`, `{:unprocessable, code, message}`,
  `{:conflict, code, message}`, `{:unconfigured, provider}` (a missing
  integration, as `Ravix.Providers` names it), `{:reauthenticate, message}`
  (the person's GitHub token is gone), or a `%Ravix.Fountain.Error{}` /
  `%Ravix.GitHub.Error{}` passed through from the client that produced it.
  """

  alias Ravix.Accounts.Access
  alias Ravix.Accounts.Inference
  alias Ravix.Accounts.User
  alias Ravix.Analytics
  alias Ravix.Fountain.Client
  alias Ravix.Hub
  alias Ravix.People
  alias Ravix.Projects.{Machine, MachineState, Project, Settings, Store, View}
  alias Ravix.Projects.Machine.Provisioned
  alias Ravix.Spec
  alias Ravix.Workspaces.Repositories
  alias Ravix.Workspaces.Workspace

  @typedoc "How the caller reaches a project. See `Ravix.Accounts.Access.access_of/3`."
  @type access :: Ravix.Accounts.Access.access()

  @typedoc "Whether a project has a machine. See `Ravix.Projects.MachineState`."
  @type machine :: MachineState.t()

  @type reason ::
          :not_found
          | {:not_found, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:conflict, String.t(), String.t()}
          | {:unconfigured, :fountain | :github}
          | {:reauthenticate, String.t()}
          | Ravix.Fountain.Error.t()
          | Ravix.GitHub.Error.t()
          | Ecto.Changeset.t()

  @doc """
  The credential name is load-bearing.

  Only `GITHUB_TOKEN` and `GH_TOKEN` get git's basic-auth rule from the
  broker. A GitHub *connection* is brokered too, but under
  `GITHUB_ACCESS_TOKEN` and as a bearer, which git over HTTPS does not use,
  so a connection buys the agent the GitHub API and not a checkout. Renaming
  this silently turns every private clone into a 403.
  """
  @spec clone_secret_key() :: String.t()
  def clone_secret_key, do: "GITHUB_TOKEN"

  # ── reading ───────────────────────────────────────────────────────────

  @doc """
  The caller's own projects, then the ones they were let into.

  A project somebody let you into shows in the rail beside your own, whether
  they let you into the whole thing or into one track of it; the alternative
  is a track with no home in the sidebar. What it is marked decides which
  controls the rail draws; the functions behind them refuse the rest
  regardless. Each project carries its machine state, one memoised Fountain
  list per project through `Ravix.MachineCache.conversations/3`. Pass
  `include_machine: false` for a database-only membership read; machine state
  is then `:none` until the caller loads that project separately.

  Five reads however long the rail is. The memberships are read once each,
  the projects behind the track memberships in one query, the owners of
  every guest project in another, and how the caller reaches each project
  is answered from the memberships already in hand rather than asked of the
  database again per row. It was one project read per shared track and
  three more per guest project before, which for a person helping across a
  team's projects was the largest thing the page did.
  """
  @spec list(User.t(), include_machine: boolean()) :: [View.t()]
  def list(%User{} = user, opts \\ []) do
    mine = Store.projects_of(user.id)

    # ownership: these two *are* how this caller's access is established --
    # `list/1` is "every project this person may see", and a membership row is
    # what makes one of them visible. There is no door earlier than this one.
    whole = People.Store.member_projects(user.id)
    tracks = People.Store.member_tracks(user.id)

    # The fourth way in, when the switch lets it count (`Access.access_of/3`).
    %{projects: in_workspaces, workspaces: workspaces, workspace_ids: workspace_ids} =
      Access.workspace_reach(user)

    # The same read names each workspace project's container (RAV-128).
    reach = Map.new(workspaces, &{&1.id, &1})

    # The projects behind the track memberships, in the order the tracks were
    # cut: the order the rail has always drawn them in, kept through the map.
    track_project_ids = tracks |> Enum.map(& &1.project_id) |> Enum.uniq()
    by_id = Map.new(Store.get_projects(track_project_ids), &{&1.id, &1})
    partial = Enum.map(track_project_ids, &Map.get(by_id, &1))

    seen = MapSet.new(mine, & &1.id)

    {guest, _seen} =
      Enum.reduce(whole ++ in_workspaces ++ partial, {[], seen}, fn
        %Project{archived_at: nil, deletion_requested_at: nil} = project, {acc, seen} ->
          if MapSet.member?(seen, project.id),
            do: {acc, seen},
            else: {[project | acc], MapSet.put(seen, project.id)}

        _project, state ->
          state
      end)

    guest = Enum.reverse(guest)
    owners = owners_of(guest, user)

    known = [
      projects: MapSet.new(whole, & &1.id),
      workspaces: MapSet.new(workspace_ids),
      tracks: MapSet.new(tracks, & &1.project_id)
    ]

    for project <- mine ++ guest do
      access = access_of(user.id, project, known)

      machine =
        if Keyword.get(opts, :include_machine, true),
          do: Machine.state(project),
          else: Machine.none()

      present(
        project,
        access,
        machine,
        Map.get(owners, project.user_id, user),
        label_workspace(project, user, reach)
      )
    end
  end

  @doc """
  One project, as the header and the composer above a track read it.

  A member needs the project's name, repository and model to render the
  header and the composer above their track. They are given exactly that,
  the same shape everyone gets, marked with how they got here, and every
  function that would *change* any of it goes through `project_of/2` and
  refuses them.
  """
  @spec get(User.t(), String.t()) :: {:ok, View.t()} | {:error, :not_found}
  def get(%User{} = user, id) do
    with %Project{archived_at: nil} = project <- Store.live_project(id) || {:error, :not_found},
         access when not is_nil(access) <- access_of(user.id, project) do
      {:ok,
       present(
         project,
         access,
         Machine.state(project),
         owner_of(project, user),
         label_workspace(project, user, nil)
       )}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Whether the caller can see a live project, including through a track invitation."
  @spec visible?(User.t(), String.t()) :: boolean()
  def visible?(%User{} = user, id) do
    case Store.live_project(id) do
      %Project{} = project -> not is_nil(access_of(user.id, project))
      _ -> false
    end
  end

  @doc "Cached funding status for a visible project. Unknown availability never blocks work."
  @spec agent_health(User.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def agent_health(%User{} = user, id) do
    with %Project{} = project <- Store.live_project(id),
         access when not is_nil(access) <- access_of(user.id, project) do
      # ownership: Access.access_of above established a project or track membership.
      # Always reload the owner: the socket's user may predate a disconnect.
      owner = Ravix.Accounts.Store.get_user(project.user_id)

      usable =
        case owner && Inference.usable?(owner, project.runtime, []) do
          {:ok, value} -> value
          _ -> nil
        end

      {:ok,
       %{
         runtime: project.runtime,
         owner_login: owner && owner.login,
         owner?: access == :owner,
         usable?: usable,
         exhausted_until: chatgpt_reset(owner, project.runtime, usable)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  # Only expose the reset time, never the owner's account details.
  defp chatgpt_reset(%User{} = owner, "codex", true) do
    with {:ok, held} <- Inference.cached_held(owner),
         true <- {:codex, :subscription} in held,
         {:ok, %{status: "active", exhausted_until: until}} when is_binary(until) <-
           Inference.cached_subscription(owner) do
      until
    else
      _ -> nil
    end
  end

  defp chatgpt_reset(_owner, _runtime, _usable), do: nil

  @doc "Owned projects affected by removing an agent; never includes shared projects."
  @spec projects_using_agent(User.t(), User.agent()) :: [Project.t()]
  def projects_using_agent(%User{} = user, agent) do
    Store.projects_of(user.id)
    |> Enum.filter(&(&1.runtime == Atom.to_string(agent)))
  end

  @doc """
  How the caller reaches a project, or nil when they do not.

  `Ravix.Accounts.Access.access_of/3`, which is where the answer lives now
  that `Ravix.Tracks` asks the same question of the same project; this is
  the name `list/1` and `get/2` already knew it by.
  """
  @spec access_of(String.t(), Project.t(), Ravix.Accounts.Access.known()) :: access() | nil
  def access_of(user_id, %Project{} = project, known \\ []),
    do: Ravix.Accounts.Access.access_of(user_id, project, known)

  # ── the machine ───────────────────────────────────────────────────────

  @doc """
  A repository becomes a machine.

  The repository is read as the *installation* rather than as the person, so
  a private repo resolves and its default branch is real. Reading it also
  proves the installation actually grants it, which is the check that stops
  somebody pointing a project at a repository they merely know the name of.

  `attrs` (string or atom keys): `name`, `repo` (`owner/name`),
  `installation_id`, and optional `runtime` ("claude" or "codex").
  The runtime defaults to the owner's agent choice, then the catalog default.
  The owner must hold a credential for that runtime, checked authoritatively
  before any Fountain records are created. Provider errors refuse creation.
  Repository projects use GitHub’s full repository name, ignoring `name`.
  A name is required for a scratch project.
  """
  @spec create(User.t(), map()) :: {:ok, View.t()} | {:error, reason()}
  def create(%User{} = user, attrs) do
    with {:ok, client} <- fountain(),
         {:ok, input} <- parse_create(attrs),
         {:ok, input} <- resolve_repo(user, input),
         {:ok, input} <- require_name(input),
         {:ok, harness} <-
           Machine.creation_harness(client, input.runtime || Inference.runtime(user)),
         :ok <- require_connected_agent(user, harness.runtime),
         project = %Project{
           id: Ecto.UUID.generate(),
           user_id: user.id,
           name: input.name,
           repo_full_name: input.repo,
           repo_private: input.private,
           default_branch: input.default_branch,
           installation_id: input.installation_id,
           instructions: "",
           runtime: harness.runtime
         },
         {:ok, ids} <- Machine.provision(project, user, client, harness),
         {:ok, project} <- insert_provisioned(project, ids, client) do
      Analytics.track(
        user,
        :project_created,
        Map.merge(Analytics.repo(nil, project), %{"ravix.repo_private" => project.repo_private})
      )

      if user.agent && project.runtime != Inference.runtime(user) do
        Analytics.track(user, :project_created_non_default_agent, %{
          "ravix.agent" => project.runtime,
          "ravix.default_agent" => Inference.runtime(user)
        })
      end

      {:ok, present(project, :owner, Machine.none(), user)}
    end
  end

  @typedoc """
  A repository a workspace admits, as `Ravix.Workspaces.Repositories` resolved
  it through the workspace's own connection: GitHub's current spelling and
  numeric id, and the connection (`workspace_installation_id`) and
  installation whose authority clones it.
  """
  @type admission :: %{
          required(:workspace_id) => String.t(),
          required(:workspace_installation_id) => String.t(),
          required(:installation_id) => integer(),
          required(:repo) => Ravix.GitHub.Shapes.RepoRef.t(),
          optional(:runtime) => String.t() | nil
        }

  @doc """
  A workspace repository becomes its project (ADR 0009 phase 4b).

  As `create/2`, with two differences. The repository was resolved through
  the workspace's installation rather than the caller's own GitHub token, so
  a member with no personal access to it still admits it; and the row is the
  workspace's canonical project for that repository. The caller must hold
  `:create_project` in the workspace (`Access.workspace_grant/3`, asked
  again here), and is the project's legacy owner, whose agent it spends
  (ADR 0005).

  `{:error, :exists}` when another admission of the same repository won the
  partial unique index first; this one's Fountain records are taken back
  and the caller reads the winner.
  """
  @spec admit(User.t(), admission()) :: {:ok, Project.t()} | {:error, :exists | reason()}
  def admit(%User{} = user, %{workspace_id: workspace_id, repo: repo} = admission) do
    with {:ok, _access} <-
           Ravix.Accounts.Access.workspace_grant(user, workspace_id, :create_project),
         {:ok, client} <- fountain(),
         {:ok, harness} <-
           Machine.creation_harness(client, admission[:runtime] || Inference.runtime(user)),
         :ok <- require_connected_agent(user, harness.runtime),
         project = %Project{
           id: Ecto.UUID.generate(),
           user_id: user.id,
           name: repo.full_name,
           repo_full_name: repo.full_name,
           repo_private: repo.private == true,
           default_branch: repo.default_branch,
           installation_id: admission.installation_id,
           instructions: "",
           runtime: harness.runtime
         },
         {:ok, ids} <- Machine.provision(project, user, client, harness) do
      insert_admitted(user, project, ids, client, admission)
    end
  end

  defp insert_admitted(user, project, %Provisioned{} = ids, client, admission) do
    attrs =
      project
      |> Map.take(
        ~w(id user_id name repo_full_name repo_private default_branch installation_id instructions)a
      )
      |> Map.merge(%{
        environment_id: ids.environment_id,
        vault_id: ids.vault_id,
        agent_id: ids.agent_id,
        runtime: ids.runtime,
        model: ids.model,
        credential_set_id: ids.credential_set_id,
        workspace_id: admission.workspace_id,
        workspace_installation_id: admission.workspace_installation_id,
        github_repo_id: admission.repo.id
      })

    case Store.create_admitted(attrs) do
      {:ok, row} ->
        Analytics.track(
          user,
          :project_created,
          Map.merge(Analytics.repo(nil, row), %{"ravix.repo_private" => row.repo_private})
        )

        {:ok, row}

      {:error, changeset} ->
        Machine.unwind(client, ids)

        if Keyword.has_key?(changeset.errors, :repo_full_name),
          do: {:error, :exists},
          else: {:error, changeset}
    end
  end

  # The same resolved runtime is checked and provisioned. A cached answer is
  # insufficient at the point where this request starts creating paid resources.
  defp require_connected_agent(owner, runtime) do
    case Inference.usable?(owner, runtime, fresh: true) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        agent = Map.get(%{"claude" => "Claude Code", "codex" => "Codex"}, runtime, runtime)

        {:error,
         {:conflict, "agent_not_connected", "Connect #{agent} before creating a project with it."}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Everything the settings dialog edits. Owner only."
  @spec settings(User.t(), String.t()) :: {:ok, Settings.t()} | {:error, reason()}
  def settings(%User{} = user, id) do
    with {:ok, project} <- Ravix.Accounts.Access.project_of(user, id),
         {:ok, client} <- fountain() do
      Settings.read(project, client)
    end
  end

  @doc """
  Save the settings dialog. Runtime switches require `rebuild: true`; owner only.

  The revision is bumped whenever something Fountain injects at *session*
  start changes, which is not the same set as "things that changed". A setup
  script is applied when the disk is built; a secret reaches the next track
  and no earlier. Tracks already open carry the old revision in their channel
  id and are badged accordingly, which is true and costs nothing to compute.
  Publishes `settings` with the resulting `rev`.
  """
  @spec update_settings(User.t(), String.t(), map()) ::
          {:ok, %{rev: integer()}} | {:error, reason()}
  def update_settings(%User{} = user, id, attrs) do
    with {:ok, project} <- Ravix.Accounts.Access.project_of(user, id),
         {:ok, client} <- fountain(),
         {:ok, rev} <- Settings.update(project, attrs, client) do
      Hub.publish(project.id, :settings)
      {:ok, %{rev: rev}}
    end
  end

  @doc "Owner acknowledgement that an uncertain secret change has finished at Fountain."
  @spec confirm_secret_change(User.t(), String.t(), integer()) :: :ok | {:error, term()}
  def confirm_secret_change(%User{} = user, id, generation) do
    with {:ok, _} <- Ravix.Accounts.Access.project_of(user, id) do
      Ravix.Cluster.project_mutation(id, :secret_change, fn ->
        confirm_secret_change_locked(user, id, generation)
      end)
    end
  end

  defp confirm_secret_change_locked(user, id, generation) do
    with {:ok, _} <- Ravix.Accounts.Access.project_of(user, id),
         :ok <- Store.confirm_secret_change(id, generation) do
      Hub.publish(id, :settings)
      :ok
    else
      {:error, :stale_secret_confirmation} ->
        {:error,
         {:conflict, "stale_secret_confirmation",
          "This secret change is no longer awaiting confirmation. Reopen Settings to check the latest change."}}

      error ->
        error
    end
  end

  @doc """
  A new machine, the same settings. Owner only.

  Retiring the *agent* is what changes the identity, and it leaves the
  environment and the vault, and therefore every repository, package and
  secret, exactly where they were. Every track is closed with it, because a
  track is a worktree on a disk that is about to stop existing and a sidebar
  full of rows pointing at nothing is worse than an empty one.
  """
  @spec rebuild(User.t(), String.t()) :: {:ok, Machine.Rebuild.t()} | {:error, reason()}
  def rebuild(%User{} = user, id) do
    with {:ok, project} <- Ravix.Accounts.Access.project_of(user, id),
         {:ok, client} <- fountain() do
      Machine.rebuild(project, client)
    end
  end

  @doc """
  Point the project at another repository (RAV-38 decision 3, RAV-76).
  Owner only.

  The Ravix GitHub App must already read the new repository: a workspace
  project's through one of the workspace's connections
  (`Ravix.Workspaces.Repositories.readable/3`, which takes
  `:create_project` and refuses a repository the workspace already has a
  project for), any other project's through an installation the owner can
  see, as `create/2` checks. Nothing is written before that answers.

  Then the machine is rebuilt on it and every track is closed, because a
  track is a branch of the old repository on the old disk. The project's
  settings, secrets, members and history stay. See
  `Ravix.Projects.Machine.change_repository/3` for the order, and for
  `{:error, {:not_rebuilt, reason}}`: the repository changed and the
  rebuild did not happen.
  """
  @spec change_repository(User.t(), String.t(), String.t() | nil) ::
          {:ok, Machine.Rebuild.t()} | {:error, reason() | {:not_rebuilt, reason()}}
  def change_repository(%User{} = user, id, full_name) do
    with {:ok, project} <- Ravix.Accounts.Access.project_of(user, id),
         {:ok, wanted} <- parse_repo_name(full_name),
         :ok <- not_current(project, wanted),
         {:ok, client} <- fountain(),
         {:ok, target} <- readable_repo(user, project, wanted) do
      Machine.change_repository(project, target, client)
    end
  end

  @doc """
  The repositories `change_repository/3` could move the project to, as
  `%{repo: "owner/name", private: boolean}`, for the Danger zone's picker:
  the workspace catalog's repositories without a project yet (the same list
  New track's "Add a repository…" shows), or the repositories of the
  owner's installations. Owner only. The offer, not the check:
  `change_repository/3` asks GitHub again.
  """
  @spec repository_choices(User.t(), String.t()) ::
          {:ok, [%{repo: String.t(), private: boolean()}]} | {:error, reason()}
  def repository_choices(%User{} = user, id) do
    with {:ok, project} <- Ravix.Accounts.Access.project_of(user, id),
         {:ok, repos} <- choices(user, project) do
      current = Project.normalize_repo(project.repo_full_name)

      {:ok,
       repos
       |> Enum.reject(&(Project.normalize_repo(&1.repo) == current))
       |> Enum.uniq_by(&Project.normalize_repo(&1.repo))}
    end
  end

  defp choices(user, %Project{workspace_id: workspace_id} = project) do
    if workspace_repos?(project) do
      with {:ok, %{repos: repos}} <- Repositories.catalog(user, workspace_id) do
        {:ok,
         for(
           %{repo: repo, project: nil} <- repos,
           do: %{repo: repo.full_name, private: repo.private == true}
         )}
      end
    else
      with {:ok, app} <- github(),
           {:ok, token} <- user_token(user),
           {:ok, installations} <- reauth_on_401(Ravix.GitHub.installations_for(app, token)) do
        {:ok,
         Enum.flat_map(installations, fn installation ->
           case Ravix.GitHub.repositories(app, token, installation.id) do
             {:ok, repos} -> Enum.map(repos, &%{repo: &1.full_name, private: &1.private == true})
             {:error, _} -> []
           end
         end)}
      end
    end
  end

  # A project in a workspace reaches GitHub through the workspace's
  # connections while workspaces are on; any other through its owner's.
  defp workspace_repos?(%Project{workspace_id: id}),
    do: is_binary(id) and Ravix.Workspaces.enabled?()

  defp parse_repo_name(full_name) when is_binary(full_name) do
    trimmed = String.trim(full_name)

    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, trimmed) and
         String.length(trimmed) <= 200,
       do: {:ok, trimmed},
       else: invalid_repo_name()
  end

  defp parse_repo_name(_full_name), do: invalid_repo_name()

  defp invalid_repo_name,
    do:
      {:error,
       {:unprocessable, "invalid_repo",
        "Enter the repository as owner/name, as GitHub spells it."}}

  defp not_current(%Project{repo_full_name: current}, wanted) do
    if Project.normalize_repo(current) == Project.normalize_repo(wanted),
      do: {:error, {:conflict, "same_repo", "This project already uses #{wanted}."}},
      else: :ok
  end

  defp readable_repo(user, project, wanted) do
    if workspace_repos?(project) do
      Repositories.readable(user, project.workspace_id, wanted)
    else
      with {:ok, app} <- github(),
           {:ok, token} <- user_token(user),
           {:ok, installations} <-
             reauth_on_401(Ravix.GitHub.installations_for(app, token, :fresh)) do
        find_readable(app, token, installations, wanted)
      end
    end
  end

  # The first of the owner's installations that grants it. Listed as the
  # owner, so it is a repository they can see and the App can read.
  defp find_readable(_app, _token, [], _wanted), do: not_readable()

  defp find_readable(app, token, [installation | rest], wanted) do
    with {:ok, repos} <-
           reauth_on_401(Ravix.GitHub.repositories(app, token, installation.id, :fresh)) do
      case find_repo(repos, wanted) do
        {:ok, repo} ->
          {:ok, %{repo: repo, installation_id: installation.id, workspace_installation_id: nil}}

        {:error, _} ->
          find_readable(app, token, rest, wanted)
      end
    end
  end

  defp not_readable,
    do:
      {:error,
       {:not_found, "repo_not_readable",
        "The Ravix GitHub App cannot read that repository. Install the App on it, or grant it that repository, and try again."}}

  @doc "The machine, its settings and its secrets. Owner only."
  @spec destroy(User.t(), String.t()) :: :ok | {:error, reason()}
  def destroy(%User{} = user, id) do
    with {:ok, project} <- Ravix.Accounts.Access.project_of(user, id),
         {:ok, client} <- fountain() do
      Machine.destroy(project, client)
    end
  end

  @doc """
  The agent's system prompt: the contract, plus whatever the person added.

  The order is not negotiable. The worktree rule goes first and the person's
  instructions go after, because the rule is what keeps tracks from writing
  over each other and an instruction file that opened with "ignore previous
  instructions" should not be able to undo it by being first.
  """
  @spec compose_system(Project.t()) :: String.t()
  def compose_system(%Project{} = project) do
    base = Spec.system_prompt(project)

    case String.trim(project.instructions || "") do
      "" -> base
      extra -> "#{base}\n\n## This project's own instructions\n\n#{extra}"
    end
  end

  @doc "The runtime and model, reconciled with what this Fountain actually has. See `Ravix.Projects.Machine.pick_runtime/1`."
  @spec pick_runtime(Ravix.Fountain.Shapes.Catalog.t(), String.t() | nil) :: Machine.Harness.t()
  defdelegate pick_runtime(catalog, wanted \\ nil), to: Machine

  @doc "`refresh_clone_token/2` on this deployment's Fountain client."
  @spec refresh_clone_token(%{vault_id: String.t(), installation_id: integer()}) ::
          :ok | {:error, reason()}
  def refresh_clone_token(ids) do
    with {:ok, client} <- fountain(), do: Machine.refresh_clone_token(ids, client)
  end

  @doc "`prepare_machine/2` on this deployment's Fountain client."
  @spec prepare_machine(Project.t()) :: :ok | {:error, reason()}
  def prepare_machine(%Project{} = project) do
    with {:ok, client} <- fountain(), do: Machine.prepare_machine(project, client)
  end

  @doc "The clone token, re-minted into the vault. See `Ravix.Projects.Machine.refresh_clone_token/2`."
  @spec refresh_clone_token(%{vault_id: String.t(), installation_id: integer()}, Client.t()) ::
          :ok | {:error, reason()}
  defdelegate refresh_clone_token(ids, client), to: Machine

  @doc "Everything a project needs before its machine is woken. See `Ravix.Projects.Machine.prepare_machine/2`."
  @spec prepare_machine(Project.t(), Client.t()) :: :ok | {:error, reason()}
  defdelegate prepare_machine(project, client), to: Machine

  # ── GitHub, as the picker sees it ─────────────────────────────────────

  @doc """
  The picker's list.

  Read with the **user's** token, which answers "what may *you* see":
  installations, and the repositories inside them. Asking the App would list
  every account that ever installed ravix. No installation at all is not an
  error: it is the state everybody is in before they grant access, and the
  picker renders an invitation to do so.

  With no installation filter, returns repositories from every account the
  person can access, retaining each repository's installation for creation.
  An explicit installation id still narrows the agent tooling's listing.
  """
  @spec repos(User.t(), integer() | nil) ::
          {:ok,
           %{
             installations: [Ravix.GitHub.Shapes.Installation.t()],
             selected: integer() | nil,
             repos: [Ravix.GitHub.Shapes.RepoRef.t()]
           }}
          | {:error, reason()}
  def repos(%User{} = user, wanted \\ nil) do
    with {:ok, app} <- github(),
         {:ok, token} <- user_token(user),
         {:ok, installations} <- reauth_on_401(Ravix.GitHub.installations_for(app, token)) do
      repos_of(app, token, installations, wanted)
    end
  end

  defp repos_of(_app, _token, [], _wanted),
    do: {:ok, %{installations: [], selected: nil, repos: []}}

  defp repos_of(app, token, installations, nil) do
    # Assume a handful of accounts per person; reads use GitHub's existing cache.
    # TODO WHEN picker reads exceed 2s p95 for users with 5+ installations,
    # measure the per-account spans before adding concurrent reads.
    result =
      Enum.reduce_while(installations, {:ok, []}, fn installation, {:ok, lists} ->
        case reauth_on_401(Ravix.GitHub.repositories(app, token, installation.id)) do
          {:ok, repos} -> {:cont, {:ok, [repos | lists]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, lists} <- result do
      repos = lists |> List.flatten() |> Enum.sort_by(&String.downcase(&1.full_name))
      {:ok, %{installations: installations, selected: nil, repos: repos}}
    end
  end

  defp repos_of(app, token, [first | _] = installations, wanted) do
    chosen = if wanted && Enum.any?(installations, &(&1.id == wanted)), do: wanted, else: first.id

    with {:ok, list} <- reauth_on_401(Ravix.GitHub.repositories(app, token, chosen)) do
      {:ok, %{installations: installations, selected: chosen, repos: list}}
    end
  end

  @doc """
  The three tabs of "create from".

  One function rather than three because the picker switches tabs without
  changing what it is asking about, and three would be three places to
  forget the installation check.

  Open to project members, because they can open tracks and this is the list
  they open one *from*. It is read as the **installation** rather than as the
  caller, so it shows the repository the project is on and nothing else of
  theirs, which is the same set the project's own header already names.
  """
  @spec refs(User.t(), String.t(), :branches | :pulls | :issues | String.t()) ::
          {:ok, [map()]} | {:error, reason()}
  def refs(%User{} = user, project_id, kind) do
    with {:ok, app} <- github(),
         {:ok, %{project: project}} <- Ravix.Accounts.Access.project_access(user, project_id),
         {:ok, project} <-
           require_repo(
             project,
             "This project has no repository, so there is nothing to start from."
           ) do
      case kind do
        k when k in [:pulls, "pulls"] ->
          Ravix.GitHub.pulls(app, project.installation_id, project.repo_full_name)

        k when k in [:issues, "issues"] ->
          Ravix.GitHub.issues(app, project.installation_id, project.repo_full_name)

        _branches ->
          Ravix.GitHub.branches(
            app,
            project.installation_id,
            project.repo_full_name,
            project.default_branch || "main"
          )
      end
    end
  end

  # ── shapes ────────────────────────────────────────────────────────────

  @doc "The `Project` map for a row, looking up the owner's login."
  @spec present(Project.t(), access(), machine()) :: View.t()
  # ownership: the project's own `user_id` column, turned into the owner's
  # login for the view. The caller holds `project` because it reached it
  # through `access_of/2`, `Access.project_of/2`, or a verified invite hash
  # in `People.link_target/2`; nothing is decided here.
  def present(%Project{} = project, access, machine),
    do: present(project, access, machine, Ravix.Accounts.Store.get_user(project.user_id))

  @doc """
  The `Project` map for a row. `role` is the owner/not-owner question almost
  every gate in the UI asks; `access` is the second question, asked in the
  two places that need it.

  `workspace` is the project's workspace when it is what the name is read
  against for this viewer (`label_workspace/3`); nil reads the legacy way,
  as a project with no workspace does, and as one whose workspace does not
  yet count for access does while the switch is off.
  """
  @spec present(Project.t(), access(), machine(), User.t() | nil, Workspace.t() | nil) ::
          View.t()
  def present(%Project{} = project, access, machine, owner, workspace \\ nil) do
    owner_login = (owner && owner.login) || ""
    {container, container_id} = container(project, access, owner_login, workspace)

    view = %View{
      id: project.id,
      name: project.name,
      display_name: project.name,
      container: container,
      container_id: container_id,
      repo: project.repo_full_name,
      repo_private: project.repo_private == true,
      default_branch: project.default_branch,
      repo_path: Project.repo_path(project),
      runtime: project.runtime,
      model: project.model,
      rev: project.rev,
      machine: machine,
      created_at: project.created_at,
      owner_login: owner_login,
      role: if(access == :owner, do: :owner, else: :member),
      access: access,
      workspace_id: project.workspace_id,
      legacy_duplicate: not is_nil(project.legacy_duplicate_at)
    }

    %{view | display_name: View.label(view)}
  end

  # What the name is read against (RAV-128): the container the project
  # lives in, and only where the viewer is not already inside it.
  #
  # A workspace project is the workspace's repository (ADR 0009), so its
  # container is the workspace, named the same for its creator and every
  # other member: the creator is attribution, not an owner anybody is
  # looking in on. A legacy project is still its owner's (ADR 0005): the
  # owner reads the bare name, and anyone it is shared with reads whose it
  # is. An owner whose account is gone has no login to show, so the name
  # stands alone rather than behind an empty prefix. The id beside the name
  # is the workspace's, for a surface scoped to it to drop the prefix
  # (`View.prefix/2`); a person's is nil, because no surface sits inside one.
  defp container(%Project{workspace_id: id}, _access, _owner_login, %Workspace{id: id} = ws),
    do: {ws.name, ws.id}

  defp container(_project, :owner, _owner_login, _workspace), do: {nil, nil}
  defp container(_project, _access, "", _workspace), do: {nil, nil}
  defp container(_project, _access, owner_login, _workspace), do: {owner_login, nil}

  # The workspace `present/5` reads a project's name against for `user`, or
  # nil for legacy labelling: the project's own, when the switch lets a
  # membership count and `user` is a live member of it -- the same facts
  # `Access.access_of/3` admits them on -- and not a personal workspace. A
  # personal workspace has one member, who is already inside it, and is
  # named after a login, which would read as the retired creator prefix
  # rather than as a place; so a personal-workspace project reads bare
  # wherever it is shown, as the owner's own project always has.
  #
  # `reach` is `Access.workspace_reach/1`'s workspaces keyed by id, when the
  # caller lists several projects and has them in hand; `get/2` asks the
  # door for the one it needs.
  defp label_workspace(%Project{workspace_id: id}, %User{} = user, reach) when is_binary(id) do
    workspace =
      case reach do
        %{} -> Map.get(reach, id)
        nil -> reached_workspace(user, id)
      end

    if workspace && workspace.kind != :personal, do: workspace
  end

  defp label_workspace(%Project{}, _user, _reach), do: nil

  defp reached_workspace(user, workspace_id) do
    with true <- Ravix.Config.workspace_access?(),
         {:ok, %{workspace: workspace}} <- Access.workspace_access(user, workspace_id) do
      workspace
    else
      _ -> nil
    end
  end

  # ── plumbing ──────────────────────────────────────────────────────────

  # The two integrations, by the names the functions above use. A
  # deployment with no `FOUNTAIN_API_KEY` can still sign people in and show
  # them their repositories, which is enough of the app working to be
  # confusing, so the refusal names what is missing -- but it is
  # `Ravix.Providers`' refusal, passed up as it is, and the sentence for it
  # is `RavixWeb.Error`'s. `Ravix.Projects.Machine` and `.Settings` take the
  # client as an argument and reach `Ravix.Providers` themselves.
  defp fountain, do: Ravix.Providers.fountain()
  defp github, do: Ravix.Providers.github()

  # ownership: the project's own `user_id`, read to show a member who owns
  # what they are looking at. `list/1` and `get/2` established the caller's
  # seat on the project with `Access.access_of/3` before asking.
  defp owner_of(%Project{user_id: user_id}, %User{id: user_id} = user), do: user

  defp owner_of(%Project{user_id: user_id}, user),
    do: Ravix.Accounts.Store.get_user(user_id) || user

  # `owner_of/2` for the whole rail: one read for every owner the guest
  # projects have between them, keyed by id. The caller is not read again
  # for their own projects, and an owner who cannot be found falls back to
  # the caller at the lookup, as `owner_of/2` does.
  defp owners_of([], _user), do: %{}

  defp owners_of(projects, %User{} = user) do
    # ownership: the same door as `owner_of/2` -- these are the guest
    # projects `list/1` puts through `Access.access_of/3`, and their own
    # `user_id` columns are what is read.
    ids = projects |> Enum.map(& &1.user_id) |> Enum.uniq() |> Enum.reject(&(&1 == user.id))
    Map.new(Ravix.Accounts.Store.get_users(ids), &{&1.id, &1})
  end

  # The user's GitHub OAuth token, decrypted. Used for anything read as *them*.
  defp user_token(user) do
    case Ravix.Accounts.user_token(user) do
      {:ok, token} -> {:ok, token}
      {:error, :no_token} -> {:error, {:reauthenticate, "Sign in with GitHub again."}}
    end
  end

  # This call uses the person's OAuth token. A 401 means it must be renewed;
  # installation permissions and provider outages need different remedies.
  defp reauth_on_401({:error, %Ravix.GitHub.Error{status: 401}}) do
    {:error,
     {:reauthenticate,
      "Your GitHub sign-in has expired or was revoked. Sign in again to load your repositories."}}
  end

  defp reauth_on_401(result), do: result

  defp require_repo(%Project{repo_full_name: repo, installation_id: id} = project, _message)
       when is_binary(repo) and repo != "" and is_integer(id),
       do: {:ok, project}

  defp require_repo(_project, message), do: {:error, {:conflict, "no_repo", message}}

  # What `create/2` takes: repo (200 chars), installation_id, name (120 chars).
  defp parse_create(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    repo = attrs |> Map.get("repo") |> str(200) |> String.trim()
    installation_id = attrs |> Map.get("installation_id") |> integer_or_nil()

    with :ok <- validate_create_runtime(attrs["runtime"]) do
      {:ok,
       %{
         runtime: attrs["runtime"],
         repo: if(repo == "", do: nil, else: repo),
         installation_id: installation_id,
         name: attrs |> Map.get("name") |> str(120) |> String.trim(),
         default_branch: nil,
         private: false
       }}
    end
  end

  defp validate_create_runtime(runtime) when runtime in [nil, "claude", "codex"], do: :ok

  defp validate_create_runtime(_runtime),
    do: {:error, {:unprocessable, "invalid_runtime", "Choose Claude Code or Codex."}}

  defp resolve_repo(_user, %{repo: nil, installation_id: nil} = input), do: {:ok, input}

  defp resolve_repo(_user, %{repo: nil}) do
    {:error,
     {:unprocessable, "no_repo",
      "A GitHub installation must be attached to an authorized repository."}}
  end

  defp resolve_repo(_user, %{installation_id: nil}) do
    {:error,
     {:unprocessable, "no_installation",
      "Pick a repository from an account Ravix is installed on."}}
  end

  # Proves the installation grants it, and gets the branch we will cut from.
  defp resolve_repo(user, input) do
    with {:ok, app} <- github(),
         {:ok, token} <- user_token(user),
         {:ok, repos} <- Ravix.GitHub.repositories(app, token, input.installation_id, :fresh),
         {:ok, repo} <- find_repo(repos, input.repo) do
      # GitHub's own spelling of the name, not the caller's: the match is
      # case-insensitive, and the mount path and clone URL come from this.
      {:ok,
       %{
         input
         | repo: repo.full_name,
           default_branch: repo.default_branch,
           private: repo.private == true,
           name: repo.full_name
       }}
    end
  end

  defp find_repo(repos, full_name) do
    wanted = String.downcase(full_name)

    case Enum.find(repos, &(String.downcase(&1.full_name) == wanted)) do
      nil ->
        {:error,
         {:not_found, "repo_not_found", "That repository is not one this installation grants."}}

      repo ->
        {:ok, repo}
    end
  end

  defp require_name(%{name: ""}),
    do: {:error, {:unprocessable, "no_name", "Give the project a name."}}

  defp require_name(input), do: {:ok, input}

  # A row that will not insert is three Fountain records nobody can reach:
  # take them back before reporting the changeset.
  defp insert_provisioned(project, %Provisioned{} = ids, client) do
    # Written out rather than `Map.merge/2`: `ids` is a struct now, and merging
    # one puts `:__struct__` in the attrs for `cast/3` to ignore.
    attrs =
      project
      |> Map.take(
        ~w(id user_id name repo_full_name repo_private default_branch installation_id instructions)a
      )
      |> Map.merge(%{
        environment_id: ids.environment_id,
        vault_id: ids.vault_id,
        agent_id: ids.agent_id,
        runtime: ids.runtime,
        model: ids.model,
        credential_set_id: ids.credential_set_id
      })

    case Store.create_project(attrs) do
      {:ok, row} ->
        {:ok, row}

      {:error, changeset} ->
        Machine.unwind(client, ids)
        {:error, changeset}
    end
  end

  defp str(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp str(_value, _max), do: ""

  defp integer_or_nil(value) when is_integer(value) and value > 0, do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp integer_or_nil(_value), do: nil
end

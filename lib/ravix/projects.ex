defmodule Ravix.Projects do
  @moduledoc """
  Projects, which are machines.

  Creating one is four Fountain calls in a fixed order and the order is the
  whole design. Sandbox identity is `(user, agent, environment, vault)` *by
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
  `{:conflict, code, message}`, `{:unavailable, message}` (a missing
  integration), `{:reauthenticate, message}` (the person's GitHub token is
  gone), or a `%Ravix.Fountain.Error{}` / `%Ravix.GitHub.Error{}` passed
  through from the client that produced it.
  """

  alias Ravix.Accounts.User
  alias Ravix.Analytics
  alias Ravix.Fountain.Client
  alias Ravix.Hub
  alias Ravix.People
  alias Ravix.Projects.{Machine, MachineState, Project, Settings, Store, View}
  alias Ravix.Projects.Machine.Provisioned
  alias Ravix.Spec

  @typedoc "How the caller reaches a project. See `access_of/2`."
  @type access :: :owner | :project | :tracks

  @typedoc "Whether a project has a machine. See `Ravix.Projects.MachineState`."
  @type machine :: MachineState.t()

  @type reason ::
          :not_found
          | {:not_found, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:conflict, String.t(), String.t()}
          | {:unavailable, String.t()}
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
  list per project through `Ravix.MachineCache.conversations/3`.
  """
  @spec list(User.t()) :: [View.t()]
  def list(%User{} = user) do
    mine = Store.projects_of(user.id)
    seen = MapSet.new(mine, & &1.id)

    # ownership: these two *are* how this caller's access is established --
    # `list/1` is "every project this person may see", and a membership row is
    # what makes one of them visible. There is no door earlier than this one.
    guests =
      People.Store.member_projects(user.id) ++
        Enum.map(People.Store.member_tracks(user.id), &Store.get_project(&1.project_id))

    {guest, _seen} =
      Enum.reduce(guests, {[], seen}, fn
        %Project{archived_at: nil} = project, {acc, seen} ->
          if MapSet.member?(seen, project.id),
            do: {acc, seen},
            else: {[project | acc], MapSet.put(seen, project.id)}

        _project, state ->
          state
      end)

    for project <- mine ++ Enum.reverse(guest) do
      owner = owner_of(project, user)
      access = access_of(user.id, project) || :tracks
      present(project, access, Machine.state(project), owner)
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
    with %Project{archived_at: nil} = project <- Store.get_project(id) || {:error, :not_found},
         access when not is_nil(access) <- access_of(user.id, project) do
      {:ok, present(project, access, Machine.state(project), owner_of(project, user))}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  How the caller reaches a project, or nil when they do not.

  Three sources, widest first, and the order is what makes the answer
  stable: somebody who owns a project *and* somehow holds rows in it is
  still its owner, and somebody in the whole project who is also named on
  one track is still in the whole project. The narrowest answer is the one
  that has to be checked last or it wins over facts that grant more.

  One function rather than the same three-line union written out in `list`,
  `get` and the stream's gate, which is where it was drifting.
  """
  @spec access_of(String.t(), Project.t()) :: access() | nil
  def access_of(user_id, %Project{} = project) do
    cond do
      project.user_id == user_id -> :owner
      Ravix.Accounts.Access.project_member?(project.id, user_id) -> :project
      # ownership: same as `list/1`, with no door before it -- this function
      # answers "what access does this person have", so the membership rows are
      # the answer, not a shortcut past one.
      Enum.any?(People.Store.member_tracks(user_id), &(&1.project_id == project.id)) -> :tracks
      true -> nil
    end
  end

  # ── the machine ───────────────────────────────────────────────────────

  @doc """
  A repository becomes a machine.

  The repository is read as the *installation* rather than as the person, so
  a private repo resolves and its default branch is real. Reading it also
  proves the installation actually grants it, which is the check that stops
  somebody pointing a project at a repository they merely know the name of.

  `attrs` (string or atom keys): `name`, `repo` (`owner/name`),
  `installation_id`. A name is required unless a repository supplies one.
  """
  @spec create(User.t(), map()) :: {:ok, View.t()} | {:error, reason()}
  def create(%User{} = user, attrs) do
    with {:ok, client} <- fountain(),
         {:ok, input} <- parse_create(attrs),
         {:ok, input} <- resolve_repo(user, input),
         {:ok, input} <- require_name(input),
         project = %Project{
           id: Ecto.UUID.generate(),
           user_id: user.id,
           name: input.name,
           repo_full_name: input.repo,
           repo_private: input.private,
           default_branch: input.default_branch,
           installation_id: input.installation_id,
           instructions: ""
         },
         {:ok, ids} <- Machine.provision(project, user, client),
         {:ok, project} <- insert_provisioned(project, ids, client) do
      Analytics.track(
        user,
        :project_created,
        Map.merge(Analytics.repo(nil, project), %{"ravix.repo_private" => project.repo_private})
      )

      {:ok, present(project, :owner, Machine.none(), user)}
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
  Save the settings dialog: every field a mutation in place. Owner only.

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
      |> github_result()
    end
  end

  # ── shapes ────────────────────────────────────────────────────────────

  @doc "The `Project` map for a row, looking up the owner's login."
  @spec present(Project.t(), access(), machine()) :: View.t()
  def present(%Project{} = project, access, machine),
    do: present(project, access, machine, Ravix.Accounts.get_user(project.user_id))

  @doc """
  The `Project` map for a row. `role` is the owner/not-owner question almost
  every gate in the UI asks; `access` is the second question, asked in the
  two places that need it.
  """
  @spec present(Project.t(), access(), machine(), User.t() | nil) :: View.t()
  def present(%Project{} = project, access, machine, owner) do
    %View{
      id: project.id,
      name: project.name,
      repo: project.repo_full_name,
      repo_private: project.repo_private == true,
      default_branch: project.default_branch,
      repo_path: Project.repo_path(project),
      runtime: project.runtime,
      model: project.model,
      rev: project.rev,
      machine: machine,
      created_at: project.created_at,
      owner_login: (owner && owner.login) || "",
      role: if(access == :owner, do: :owner, else: :member),
      access: access
    }
  end

  # ── the integrations, or a refusal that says what is missing ──────────

  @doc """
  The Fountain client, or a refusal that says what is missing.

  A deployment with no `FOUNTAIN_API_KEY` can still sign people in and show
  them their repositories, which is enough of the app working to be
  confusing. So the failure is named rather than generic: this is the one
  variable without which ravix has no machines at all.
  """
  @spec fountain() :: {:ok, Client.t()} | {:error, {:unavailable, String.t()}}
  def fountain do
    client = Ravix.Fountain.client()

    if Client.configured?(client),
      do: {:ok, client},
      else: {:error, {:unavailable, no_fountain()}}
  end

  @doc "The GitHub App, or a refusal that says it is not configured."
  @spec github() :: {:ok, Ravix.Config.GitHubApp.t()} | {:error, {:unavailable, String.t()}}
  def github do
    case Ravix.Config.github() do
      nil -> {:error, {:unavailable, no_github()}}
      app -> {:ok, app}
    end
  end

  @doc "A Fountain result with `:unconfigured` named as the missing integration it is."
  @spec fountain_result(term()) :: term()
  def fountain_result({:error, :unconfigured}), do: {:error, {:unavailable, no_fountain()}}
  def fountain_result(other), do: other

  @doc "A GitHub result with `:unconfigured` named as the missing integration it is."
  @spec github_result(term()) :: term()
  def github_result({:error, :unconfigured}), do: {:error, {:unavailable, no_github()}}
  def github_result(other), do: other

  # ── plumbing ──────────────────────────────────────────────────────────

  defp no_fountain,
    do: "This Ravix deployment has no Fountain account configured, so it cannot build machines."

  defp no_github,
    do: "This Ravix deployment has no GitHub App configured, so it cannot see repositories."

  defp owner_of(%Project{user_id: user_id}, %User{id: user_id} = user), do: user
  defp owner_of(%Project{user_id: user_id}, user), do: Ravix.Accounts.get_user(user_id) || user

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

  defp reauth_on_401(result), do: github_result(result)

  defp require_repo(%Project{repo_full_name: repo, installation_id: id} = project, _message)
       when is_binary(repo) and repo != "" and is_integer(id),
       do: {:ok, project}

  defp require_repo(_project, message), do: {:error, {:conflict, "no_repo", message}}

  # What `create/2` takes: repo (200 chars), installation_id, name (120 chars).
  defp parse_create(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    repo = attrs |> Map.get("repo") |> str(200) |> String.trim()
    installation_id = attrs |> Map.get("installation_id") |> integer_or_nil()

    {:ok,
     %{
       repo: if(repo == "", do: nil, else: repo),
       installation_id: installation_id,
       name: attrs |> Map.get("name") |> str(120) |> String.trim(),
       default_branch: nil,
       private: false
     }}
  end

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
         {:ok, repos} <-
           github_result(Ravix.GitHub.repositories(app, token, input.installation_id)),
         {:ok, repo} <- find_repo(repos, input.repo) do
      # GitHub's own spelling of the name, not the caller's: the match is
      # case-insensitive, and the mount path and clone URL come from this.
      {:ok,
       %{
         input
         | repo: repo.full_name,
           default_branch: repo.default_branch,
           private: repo.private == true,
           name: if(input.name == "", do: repo.name, else: input.name)
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

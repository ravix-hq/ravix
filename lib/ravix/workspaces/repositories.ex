defmodule Ravix.Workspaces.Repositories do
  @moduledoc """
  A workspace's repositories: the catalog its GitHub connections reach, and
  admission of one of them as the workspace's project (ADR 0009, phase 4b).

  **The catalog** is every repository reachable through the workspace's
  live connections, read with each installation's own token and cached in
  `workspace_repositories`. Pages read the cache (`catalog/2`); only
  `refresh/2` asks GitHub. A refresh also learns when GitHub has suspended
  an installation or the App was uninstalled: the connection is marked, its
  repositories leave the catalog, and the reason is shown beside it. It
  follows renames and transfers too: a canonical project whose GitHub
  repository id now has another name is renamed to it, not duplicated.

  **Admission** (`add/3`) is the atomic re-add lookup on
  `(workspace_id, normalized_repo_full_name)`: adding a repository the
  workspace already has returns its project (RAV-13); otherwise one project
  is created, through the workspace's installation, under a cluster-wide
  lock per repository, with phase 2's partial unique index as the last
  word, so concurrent adds give one project. Marked legacy duplicates are
  never the workspace's project for a repository and never offered.

  Everything goes through the installation's authority, never the caller's
  own GitHub token, so a member without personal access to a repository
  still reaches it through the workspace.
  """

  alias Ravix.Accounts.{Access, User}
  alias Ravix.GitHub
  alias Ravix.Projects.Project
  alias Ravix.Workspaces.{CatalogRepo, Installation, Store}

  @type entry :: %{repo: CatalogRepo.t(), project: Project.t() | nil}
  @type catalog :: %{
          installations: [Installation.t()],
          repos: [entry()],
          refreshed_at: DateTime.t() | nil
        }
  @type refreshed :: %{
          errors: [{integer(), term()}],
          renamed: [String.t()],
          collisions: [String.t()]
        }

  @doc """
  The workspace's catalog, from the cache: its connections with their
  standing, and every repository they reach with the workspace's project
  for it, if it has one. Any member; nobody else.
  """
  @spec catalog(User.t(), String.t()) :: {:ok, catalog()} | {:error, :not_found | term()}
  def catalog(%User{} = user, workspace_id) do
    with {:ok, %{workspace: workspace}} <- member(user, workspace_id) do
      installations = Store.installations(workspace.id)
      projects = Store.canonical_projects(workspace.id)

      repos =
        for repo <- Store.catalog(workspace.id),
            do: %{repo: repo, project: Map.get(projects, repo.normalized_repo_full_name)}

      refreshed =
        installations
        |> Enum.filter(&(Installation.status(&1) == :active))
        |> Enum.map(& &1.refreshed_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.min(DateTime, fn -> nil end)

      {:ok, %{installations: installations, repos: repos, refreshed_at: refreshed}}
    end
  end

  @doc "Ask GitHub again for the workspace's catalog. Any member."
  @spec refresh(User.t(), String.t()) :: {:ok, refreshed()} | {:error, term()}
  def refresh(%User{} = user, workspace_id) do
    with {:ok, %{workspace: workspace}} <- member(user, workspace_id) do
      refresh_unchecked(workspace.id)
    end
  end

  @doc false
  # For `Ravix.Workspaces.Connect.finish/4`, which has just established
  # `:connect_repos` itself.
  @spec refresh_unchecked(String.t()) :: {:ok, refreshed()} | {:error, term()}
  def refresh_unchecked(workspace_id) do
    with {:ok, app} <- Ravix.Providers.github() do
      errors =
        for installation <- Store.installations(workspace_id),
            Installation.status(installation) != :revoked,
            error = refresh_installation(app, installation),
            error != :ok,
            do: {installation.installation_id, error}

      {renamed, collisions} = follow_renames(workspace_id)
      {:ok, %{errors: errors, renamed: renamed, collisions: collisions}}
    end
  end

  defp refresh_installation(app, %Installation{} = installation) do
    account = installation.account_login || "its account"

    case GitHub.installation(app, installation.installation_id) do
      {:ok, nil} ->
        Store.record_refresh(
          installation,
          :revoked,
          "The Ravix GitHub App was uninstalled from @#{account}.",
          []
        )

      {:ok, %{suspended_at: suspended}} when is_binary(suspended) ->
        Store.record_refresh(
          installation,
          :suspended,
          "GitHub has suspended the Ravix App on @#{account}.",
          []
        )

      {:ok, _active} ->
        case GitHub.installation_repositories(app, installation.installation_id) do
          {:ok, repos} ->
            Store.record_refresh(installation, :active, nil, Enum.map(repos, &row/1))

          {:error, reason} ->
            reason
        end

      {:error, reason} ->
        reason
    end
  end

  defp row(repo) do
    %{
      github_repo_id: repo.id,
      full_name: repo.full_name,
      private: repo.private,
      default_branch: repo.default_branch,
      pushed_at: repo.pushed_at
    }
  end

  # A canonical project follows its GitHub repository: by numeric id when it
  # has one, else by name, which also records the id for next time. A new
  # name another canonical project already holds is a collision, reported
  # and left alone rather than duplicated or overwritten.
  defp follow_renames(workspace_id) do
    repos = Store.catalog(workspace_id)

    by_id =
      Store.canonical_projects_by_repo_id(workspace_id, Enum.map(repos, & &1.github_repo_id))

    by_name = Store.canonical_projects(workspace_id)

    Enum.reduce(repos, {[], []}, fn repo, {renamed, collisions} ->
      project =
        Map.get(by_id, repo.github_repo_id) ||
          unclaimed(Map.get(by_name, repo.normalized_repo_full_name))

      case project && follow(project, repo) do
        :renamed -> {[repo.full_name | renamed], collisions}
        :taken -> {renamed, [repo.full_name | collisions]}
        _same -> {renamed, collisions}
      end
    end)
  end

  defp unclaimed(%Project{github_repo_id: nil} = project), do: project
  defp unclaimed(_project), do: nil

  defp follow(%Project{} = project, %CatalogRepo{} = repo) do
    if is_nil(project.github_repo_id), do: Store.set_github_repo_id(project, repo.github_repo_id)

    cond do
      project.repo_full_name == repo.full_name ->
        :same

      match?({:ok, _}, Store.rename_repo(project, repo.full_name)) ->
        Ravix.Hub.publish(project.id, :settings)
        :renamed

      true ->
        :taken
    end
  end

  @doc """
  Add a repository to the workspace: its one project.

  Any member reaches a repository the workspace already has: the existing
  project comes back with `created: false`, however the name is spelled
  (trimmed, lowercased) and whatever it has been renamed to on GitHub.
  Creating one takes `:create_project` (owners and admins), and the
  repository must be in the catalog: reachable through a live connection,
  confirmed again with that installation's token.
  """
  @spec add(User.t(), String.t(), String.t() | nil) ::
          {:ok, %{project: Project.t(), created: boolean()}} | {:error, term()}
  def add(%User{} = user, workspace_id, full_name) do
    with {:ok, %{workspace: workspace, role: role}} <- member(user, workspace_id),
         {:ok, key} <- key(full_name) do
      case Store.canonical_project(workspace.id, key) do
        %Project{} = project -> {:ok, %{project: project, created: false}}
        nil -> add_new(user, workspace.id, role, key)
      end
    end
  end

  defp add_new(user, workspace_id, role, key) do
    with :ok <- Access.require_capability(role, :create_project),
         {:ok, repo, entry} <- resolve(workspace_id, key) do
      existing_or_admit(user, workspace_id, repo, entry)
    end
  end

  defp key(full_name) do
    case Project.normalize_repo(full_name) do
      nil -> {:error, {:unprocessable, "no_repo", "Choose a repository."}}
      key -> {:ok, key}
    end
  end

  # The repository as the connection's installation sees it right now: its
  # current name and numeric id, and proof it is still granted.
  defp resolve(workspace_id, key) do
    with %CatalogRepo{} = entry <- Store.catalog_repo(workspace_id, key) || not_in_catalog(),
         {:ok, app} <- Ravix.Providers.github(),
         installation = entry.workspace_installation,
         {:ok, repo} <- GitHub.repository(app, installation.installation_id, entry.full_name) do
      {:ok, repo, entry}
    else
      {:error, %GitHub.Error{status: status}} when status in [403, 404] -> not_in_catalog()
      other -> other
    end
  end

  defp not_in_catalog,
    do:
      {:error,
       {:not_found, "repo_not_in_workspace",
        "That repository is not one this workspace's GitHub connections reach."}}

  # Renamed on GitHub since the catalog was read: the project already there
  # under the old name is the one.
  defp existing_or_admit(user, workspace_id, repo, entry) do
    case Store.canonical_projects_by_repo_id(workspace_id, List.wrap(repo.id)) do
      %{} = found when map_size(found) == 1 ->
        [project] = Map.values(found)
        _ = follow(project, %{entry | full_name: repo.full_name})
        {:ok, %{project: Store.canonical_project_by_id(project.id) || project, created: false}}

      _none ->
        admit_once(user, workspace_id, repo, entry)
    end
  end

  # One admission per repository per workspace at a time, cluster-wide, so
  # the second of two concurrent adds waits and then finds the first's
  # project instead of provisioning a machine only to have the unique index
  # refuse it. The index still decides if the lock is ever bypassed.
  defp admit_once(user, workspace_id, repo, entry) do
    key = Project.normalize_repo(repo.full_name)
    lock = {{:ravix, :admission, workspace_id, key}, self()}

    :global.trans(lock, fn -> admit_locked(user, workspace_id, key, repo, entry) end, [
      node() | Node.list()
    ])
  end

  defp admit_locked(user, workspace_id, key, repo, entry) do
    case Store.canonical_project(workspace_id, key) do
      %Project{} = project ->
        {:ok, %{project: project, created: false}}

      nil ->
        admission = %{
          workspace_id: workspace_id,
          workspace_installation_id: entry.workspace_installation_id,
          installation_id: entry.workspace_installation.installation_id,
          repo: repo
        }

        case Ravix.Projects.admit(user, admission) do
          {:ok, project} ->
            {:ok, %{project: project, created: true}}

          {:error, :exists} ->
            {:ok, %{project: Store.canonical_project(workspace_id, key), created: false}}

          {:error, _} = error ->
            error
        end
    end
  end

  defp member(user, workspace_id), do: Access.workspace_grant(user, workspace_id, :create_track)
end

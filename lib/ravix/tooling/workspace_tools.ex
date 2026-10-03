defmodule Ravix.Tooling.WorkspaceTools do
  @moduledoc "Headless workspace operations through the existing scoped contexts."
  alias Ravix.{Accounts, Config, Projects, Workspaces}
  alias Ravix.Accounts.Access
  alias Ravix.Projects.Sections
  alias Ravix.Tooling.Mutations
  alias Ravix.Workspaces.{Connect, Installation, Repositories}

  @capabilities %{
    "update_workspace" => :rename_workspace,
    "move_workspace_project" => :manage_projects,
    "invite_workspace_member" => :manage_members,
    "revoke_workspace_invitation" => :manage_members,
    "set_workspace_member_role" => :manage_roles,
    "get_workspace_connect_url" => :connect_repos,
    "get_workspace_configure_url" => :connect_repos,
    "list_available_workspace_installations" => :add_installations,
    "add_workspace_installation" => :add_installations
  }
  @section_tools ~w(update_workspace_section)
  @revocations ~w(remove_workspace_member leave_workspace)

  # These successful actions change the permission that admitted the caller.
  # Only this user's/client's completed, fingerprint-matched receipt can replay.
  # Tooling.call still checks the current OAuth grant before and after execution.
  def execute(p, "leave_workspace" = name, a), do: replay_or_execute(p, name, a)

  def execute(p, "remove_workspace_member" = name, %{"user_id" => id} = a)
      when id == p.user.id,
      do: replay_or_execute(p, name, a)

  def execute(p, "set_workspace_member_role" = name, %{"user_id" => id} = a)
      when id == p.user.id do
    with :ok <- member_access(p, a), do: replay_or_execute(p, name, a)
  end

  def execute(p, "delete_workspace_section" = name, a) do
    with :ok <- access(p, name, a),
         :none <- Mutations.replay(p, name, a),
         :ok <- own_section(p, a) do
      Mutations.run(p, name, a, fn -> perform(p, name, a) end, release: true)
    end
  end

  def execute(p, name, a) do
    with :ok <- access(p, name, a), do: run(p, name, a)
  end

  defp replay_or_execute(p, name, a) do
    with :none <- Mutations.replay(p, name, a),
         :ok <- access(p, name, a),
         do: run(p, name, a)
  end

  defp run(p, name, %{"request_id" => _} = a) do
    Mutations.run(p, name, a, fn -> perform(p, name, a) end,
      release:
        name not in ~w(add_workspace_repository add_workspace_installation refresh_workspace_repositories)
    )
  end

  defp run(p, name, a), do: perform(p, name, a)

  defp access(_p, "list_workspaces", _a), do: :ok
  defp access(p, "create_workspace", _a), do: Access.workspace_creation(p.user)

  defp access(p, "list_workspace_move_targets", a) do
    with :ok <- Access.workspace_creation(p.user),
         do: ok(Access.project_of(p.user, a["project_id"]))
  end

  defp access(p, "get_workspace", a), do: ok(Workspaces.get(p.user, a["workspace_id"]))

  defp access(p, name, a) when name in @revocations do
    with {:ok, %{role: role}} <- Workspaces.get(p.user, a["workspace_id"]) do
      if name == "remove_workspace_member",
        do: Access.require_capability(role, :manage_members),
        else: :ok
    end
  end

  defp access(p, name, a) do
    with {:ok, _} <-
           Access.workspace_grant(
             p.user,
             a["workspace_id"],
             Map.get(@capabilities, name, :create_track)
           ) do
      cond do
        name in @section_tools -> own_section(p, a)
        name == "move_workspace_placement" -> placement_access(p, a)
        name == "set_workspace_closed_visibility" -> project_home(p, a)
        name == "move_workspace_project" -> ok(Access.project_of(p.user, a["project_id"]))
        true -> :ok
      end
    end
  end

  defp own_section(p, a) do
    with {:ok, {sections, _}} <- Sections.list(p.user, a["workspace_id"]) do
      if Enum.any?(sections, &(&1.id == a["section_id"])), do: :ok, else: {:error, :not_found}
    end
  end

  defp placement_access(p, a) do
    with :ok <- project_home(p, a) do
      if a["section_id"] == "", do: :ok, else: own_section(p, a)
    end
  end

  defp project_home(p, a) do
    with {:ok, project} <- Projects.get(p.user, a["project_id"]) do
      if Workspaces.home(p.user, Workspaces.list(p.user), project) == a["workspace_id"],
        do: :ok,
        else: {:error, :not_found}
    end
  end

  defp perform(p, "list_workspaces", a),
    do: {:ok, page(Enum.map(Workspaces.list(p.user), &workspace/1), a)}

  defp perform(p, "get_workspace", a),
    do: map(Workspaces.get(p.user, a["workspace_id"]), &workspace/1)

  defp perform(p, "create_workspace", a),
    do: map(Workspaces.create(p.user, a["name"]), &workspace(%{workspace: &1, role: :owner}))

  defp perform(p, "update_workspace", a),
    do:
      map(
        Workspaces.rename(p.user, a["workspace_id"], a["name"]),
        &Map.take(&1, [:id, :name, :kind])
      )

  defp perform(p, "select_workspace", a),
    do:
      map(
        Accounts.put_current_workspace(p.user, a["workspace_id"]),
        &%{workspace_id: &1.current_workspace_id}
      )

  defp perform(p, "list_workspace_projects", a) do
    with {:ok, projects} <- Workspaces.projects(p.user, a["workspace_id"]) do
      closed = MapSet.new(Sections.closed_shown(p.user))

      items =
        Enum.map(projects, fn row ->
          Map.take(row.project, [:id, :name, :repo_full_name, :workspace_id])
          |> Map.merge(%{
            owner_login: row.owner.login,
            people: row.people,
            closed_tracks_visible: MapSet.member?(closed, row.project.id)
          })
        end)

      {:ok, page(items, a)}
    end
  end

  defp perform(p, "list_workspace_move_targets", a) do
    map(Workspaces.move_targets(p.user, a["project_id"]), fn result ->
      page(Enum.map(result.targets, &Map.take(&1, [:id, :name, :kind])), a)
      |> Map.merge(%{
        current_workspace_id: result.current && result.current.id,
        duplicate_of: result.duplicate_of
      })
    end)
  end

  defp perform(p, "move_workspace_project", a),
    do:
      map(
        Workspaces.move_project(p.user, a["project_id"], a["workspace_id"]),
        &Map.take(&1, [:id, :workspace_id])
      )

  defp perform(p, "set_workspace_closed_visibility", a),
    do:
      map(
        Sections.show_closed(p.user, a["project_id"], a["show"]),
        &%{project_id: a["project_id"], show: &1}
      )

  defp perform(p, name, a) when name in ~w(list_workspace_members list_workspace_invitations) do
    with {:ok, people} <- Workspaces.people(p.user, a["workspace_id"]) do
      items =
        if name == "list_workspace_members",
          do: Enum.map(people.members, &member/1),
          else: Enum.map(people.invites, &Map.take(&1, [:id, :login, :role, :created_at]))

      {:ok, page(items, a)}
    end
  end

  defp perform(p, "invite_workspace_member", a),
    do:
      map(
        Workspaces.invite(p.user, a["workspace_id"], a["login"], Map.get(a, "role", "member")),
        &%{status: &1}
      )

  defp perform(p, "revoke_workspace_invitation", a),
    do: done(Workspaces.revoke_invite(p.user, a["workspace_id"], a["login"]))

  defp perform(p, "set_workspace_member_role", a),
    do: done(Workspaces.set_role(p.user, a["workspace_id"], a["user_id"], a["role"]))

  defp perform(p, "remove_workspace_member", a),
    do: done(Workspaces.remove_member(p.user, a["workspace_id"], a["user_id"]))

  defp perform(p, "leave_workspace", a), do: done(Workspaces.leave(p.user, a["workspace_id"]))

  defp perform(p, "list_workspace_connections", a) do
    with {:ok, catalog} <- Repositories.catalog(p.user, a["workspace_id"]),
         do: {:ok, page(Enum.map(catalog.installations, &installation/1), a)}
  end

  defp perform(p, "list_workspace_repositories", a) do
    with {:ok, catalog} <- Repositories.catalog(p.user, a["workspace_id"]) do
      {:ok,
       page(Enum.map(catalog.repos, &repository/1), a)
       |> Map.put(:refreshed_at, catalog.refreshed_at)}
    end
  end

  defp perform(p, "refresh_workspace_repositories", a) do
    map(Repositories.refresh(p.user, a["workspace_id"]), fn report ->
      # Provider error structs may contain request/response data; select only IDs.
      %{
        failed_installations: bounded(Enum.map(report.errors, fn {id, _reason} -> id end)),
        renamed: bounded(report.renamed),
        collisions: bounded(report.collisions)
      }
    end)
  end

  defp perform(p, "list_available_workspace_installations", a),
    do:
      map(
        Connect.available(p.user, a["workspace_id"]),
        &page(Enum.map(&1, fn i -> Map.take(i, [:id, :account]) end), a)
      )

  defp perform(p, "add_workspace_installation", a) do
    with {:ok, binding} <- Connect.add(p.user, a["workspace_id"], a["installation_id"]),
         {:ok, catalog} <- Repositories.catalog(p.user, a["workspace_id"]),
         %Installation{} = current <-
           Enum.find(catalog.installations, &(&1.id == binding.id)) || {:error, :not_found} do
      {:ok, installation(current)}
    end
  end

  defp perform(p, "add_workspace_repository", a),
    do:
      map(
        Repositories.add(p.user, a["workspace_id"], a["full_name"]),
        &%{
          project: Map.take(&1.project, [:id, :name, :repo_full_name, :workspace_id]),
          created: &1.created
        }
      )

  defp perform(_p, "get_workspace_connect_url", a),
    do:
      {:ok,
       %{
         url: Config.public_url() <> "/w/#{a["workspace_id"]}/github/connect",
         browser_required: true
       }}

  defp perform(p, "get_workspace_configure_url", a),
    do: map(Connect.configure_url(p.user, a["workspace_id"]), &%{url: &1})

  defp perform(p, "list_workspace_sections", a),
    do:
      map(Sections.list(p.user, a["workspace_id"]), fn {sections, _} ->
        page(Enum.map(sections, &section/1), a)
      end)

  defp perform(p, "list_workspace_placements", a) do
    with {:ok, {_, placements}} <- Sections.list(p.user, a["workspace_id"]) do
      items =
        for {project_id, section_id} <- placements,
            Projects.visible?(p.user, project_id),
            do: %{id: project_id, project_id: project_id, section_id: section_id}

      {:ok, page(items, a)}
    end
  end

  defp perform(p, "create_workspace_section", a),
    do: map(Sections.create(p.user, a["workspace_id"], Map.take(a, ~w(name))), &section/1)

  defp perform(p, "update_workspace_section", a),
    do: map(Sections.update(p.user, a["section_id"], Map.take(a, ~w(name collapsed))), &section/1)

  defp perform(p, "delete_workspace_section", a),
    do: map(Sections.delete(p.user, a["section_id"]), &%{deleted: true, section_id: &1.id})

  defp perform(p, "move_workspace_placement", a),
    do:
      map(Sections.move(p.user, a["workspace_id"], a["project_id"], a["section_id"]), fn _ ->
        %{project_id: a["project_id"], section_id: a["section_id"]}
      end)

  def recheck(p, "list_workspaces", _a, result),
    do: all(result.items, &Workspaces.get(p.user, value(&1, :id)))

  def recheck(p, "create_workspace", _a, result),
    do: ok(Workspaces.get(p.user, value(result, :id)))

  def recheck(p, "set_workspace_member_role", %{"user_id" => id} = a, _result)
      when id == p.user.id,
      do: member_access(p, a)

  def recheck(_p, "leave_workspace", _a, _result), do: :ok

  def recheck(p, "remove_workspace_member", %{"user_id" => id}, _result) when id == p.user.id,
    do: :ok

  def recheck(p, "delete_workspace_section", a, _result),
    do: ok(Access.workspace_grant(p.user, a["workspace_id"], :create_track))

  def recheck(p, name, a, result) do
    with :ok <- access(p, name, a) do
      recheck_projects(p, name, result)
    end
  end

  defp recheck_projects(p, "list_workspace_projects", result),
    do: all(result.items, &Access.project_access(p.user, value(&1, :id)))

  defp recheck_projects(p, "list_workspace_move_targets", result),
    do: all(result.items, &Access.workspace_grant(p.user, value(&1, :id), :manage_projects))

  defp recheck_projects(p, "list_workspace_placements", result),
    do: all(result.items, &visible_project(p, value(&1, :project_id)))

  defp recheck_projects(p, "list_workspace_repositories", result) do
    all(
      Enum.filter(result.items, &value(&1, :project_id)),
      &Access.project_access(p.user, value(&1, :project_id))
    )
  end

  defp recheck_projects(p, "add_workspace_repository", result),
    do: ok(Access.project_access(p.user, value(value(result, :project), :id)))

  defp recheck_projects(_p, _name, _result), do: :ok

  defp member_access(p, a),
    do: ok(Access.workspace_grant(p.user, a["workspace_id"], :create_track))

  defp visible_project(p, id) do
    if Projects.visible?(p.user, id), do: {:ok, id}, else: {:error, :not_found}
  end

  defp all(items, check),
    do:
      Enum.reduce_while(items, :ok, fn item, _ ->
        case ok(check.(item)) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp value(map, key), do: map[key] || map[Atom.to_string(key)]
  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error
  defp done(:ok), do: {:ok, %{updated: true}}
  defp done(error), do: error
  defp map({:ok, value}, fun), do: {:ok, fun.(value)}
  defp map(error, _fun), do: error

  defp workspace(%{workspace: workspace, role: role}),
    do:
      Map.take(workspace, [:id, :name, :kind, :created_at])
      |> Map.merge(%{role: role, access_enabled: Workspaces.enabled?()})

  defp member(%{user: user, role: role}),
    do: Map.take(user, [:id, :login, :avatar_url]) |> Map.put(:role, role)

  defp installation(i),
    do:
      Map.take(i, [:id, :installation_id, :account_login, :connected_at, :refreshed_at])
      |> Map.put(:status, Installation.status(i))

  defp repository(%{repo: repo, project: project}),
    do:
      Map.take(repo, [:id, :full_name, :private, :default_branch, :github_repo_id])
      |> Map.put(:project_id, project && project.id)

  defp section(s), do: Map.take(s, [:id, :workspace_id, :name, :collapsed])
  defp bounded(items), do: %{items: Enum.take(items, 100), truncated: length(items) > 100}

  defp page(items, args) do
    rows = items |> Enum.sort_by(&key/1) |> Enum.filter(&(key(&1) > Map.get(args, "after", "")))
    limit = Map.get(args, "limit", 50)
    selected = Enum.take(rows, limit)
    %{items: selected, next_cursor: if(length(rows) > limit, do: key(List.last(selected)))}
  end

  defp key(item), do: to_string(item[:id] || item[:full_name])
end

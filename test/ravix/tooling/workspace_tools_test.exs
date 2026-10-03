defmodule Ravix.Tooling.WorkspaceToolsTest do
  use Ravix.DataCase, async: false
  use Mimic
  import Ravix.ToolingFixture
  import Ravix.WorkspaceGitHubFixture
  alias Ravix.{Accounts, Projects, Tooling, Workspaces}
  alias Ravix.Projects.Sections
  alias Ravix.Tooling.{OAuth, WorkspaceTools}
  alias Ravix.Workspaces.{Store, Workspace}

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    owner = insert_user(login: "owner", credential_set_id: "set-me", token_enc: nil)
    member = insert_user(login: "member")
    admin = insert_user(login: "admin")
    {:ok, team} = Workspaces.create(owner, "Team")
    :ok = Store.add_member(team.id, member.id, :member, owner.id)
    :ok = Store.add_member(team.id, admin.id, :admin, owner.id)
    {p, _, _} = principal(owner)
    %{owner: owner, member: member, admin: admin, team: team, p: p}
  end

  defp args(team, extra \\ %{}), do: Map.put(extra, "workspace_id", team.id)

  defp write(team, extra \\ %{}),
    do: args(team, Map.put(extra, "request_id", Ecto.UUID.generate()))

  defp as(user), do: elem(principal(user), 0)

  test "workspace creation, rename, selection persist and receipts prevent duplicates", c do
    input = %{"name" => "New", "request_id" => "new"}
    assert {:ok, created} = Tooling.call(c.p, "create_workspace", input)
    assert created.role == :owner
    assert {:ok, replay} = Tooling.call(c.p, "create_workspace", input)
    assert replay["id"] == created.id

    assert {:error, {:conflict, "request_id_used", _}} =
             Tooling.call(c.p, "create_workspace", %{input | "name" => "Different"})

    assert Repo.aggregate(from(w in Workspace, where: w.name == "New"), :count) == 1

    assert {:ok, _} =
             Tooling.call(as(c.admin), "update_workspace", write(c.team, %{"name" => "Renamed"}))

    assert {:ok, %{workspace: %{name: "Renamed"}}} = Workspaces.get(c.owner, c.team.id)
    assert {:ok, %{workspace_id: id}} = Tooling.call(c.p, "select_workspace", write(c.team))
    assert id == c.team.id
    assert Repo.get!(Accounts.User, c.owner.id).current_workspace_id == id

    assert {:error, {:unprocessable, "name", _}} =
             Tooling.call(c.p, "create_workspace", %{"name" => "   ", "request_id" => "refusal"})

    assert {:ok, _} =
             Tooling.call(c.p, "create_workspace", %{"name" => "Valid", "request_id" => "refusal"})
  end

  test "metadata pagination is scoped and does not grant project access with the flag off", c do
    foreign = insert_user()
    {:ok, other} = Workspaces.create(foreign, "Foreign")
    {:ok, second} = Workspaces.create(c.owner, "Second")
    assert {:ok, first} = Tooling.call(c.p, "list_workspaces", %{"limit" => 1})
    assert first.next_cursor

    assert {:ok, last} =
             Tooling.call(c.p, "list_workspaces", %{"limit" => 1, "after" => first.next_cursor})

    assert last.next_cursor == nil

    assert Enum.sort(Enum.map(first.items ++ last.items, & &1.id)) ==
             Enum.sort([c.team.id, second.id])

    assert {:error, :not_found} = Tooling.call(c.p, "get_workspace", args(other))
    project = insert_project(user: c.owner)
    Store.move_project(project.id, c.team.id)
    Application.put_env(:ravix, :workspace_access, false)

    assert {:ok, %{access_enabled: false}} =
             Tooling.call(as(c.member), "get_workspace", args(c.team))

    assert {:error, :not_found} = Projects.get(c.member, project.id)

    for name <-
          ~w(list_workspace_members list_workspace_invitations list_workspace_connections list_workspace_repositories list_available_workspace_installations list_workspace_sections list_workspace_placements get_workspace_connect_url get_workspace_configure_url) do
      assert {:error, :not_found} = Tooling.call(c.p, name, args(c.team))
    end

    assert {:error, :not_found} =
             Tooling.call(c.p, "create_workspace", %{"name" => "Off", "request_id" => "off"})

    assert {:error, :not_found} =
             Tooling.call(c.p, "update_workspace", write(c.team, %{"name" => "Off"}))

    assert {:ok, _} =
             Tooling.call(
               c.p,
               "remove_workspace_member",
               write(c.team, %{"user_id" => c.member.id})
             )
  end

  test "read-only and old grants cannot mutate or acquire workspace scopes", c do
    read = elem(principal(c.owner, "mcp", ["workspaces:read"]), 0)
    assert {:ok, _} = Tooling.call(read, "get_workspace", args(c.team))

    for {name, extra} <- [
          {"update_workspace", %{"name" => "No"}},
          {"remove_workspace_member", %{"user_id" => c.member.id}},
          {"create_workspace_section", %{"name" => "No"}}
        ] do
      assert {:error, {:forbidden, _}} = Tooling.call(read, name, write(c.team, extra))
    end

    {old, tokens, params} = principal(c.owner, "mcp", ["projects:read", "projects:write"])
    assert {:error, {:forbidden, _}} = Tooling.call(old, "get_workspace", args(c.team))

    assert {:ok, refreshed} =
             OAuth.exchange(%{
               "grant_type" => "refresh_token",
               "refresh_token" => tokens.refresh_token,
               "resource" => params["resource"],
               "client_id" => params["client_id"]
             })

    assert {:ok, fresh} = OAuth.authenticate(refreshed.access_token, params["resource"])
    refute "workspaces:read" in fresh.grant.scopes
    refute "workspaces:write" in fresh.grant.scopes
  end

  test "member/admin/owner constraints govern membership operations and target IDs", c do
    member = as(c.member)
    admin = as(c.admin)
    outsider = insert_user(login: "outsider")

    assert {:error, {:forbidden, _}} =
             Tooling.call(member, "update_workspace", write(c.team, %{"name" => "No"}))

    assert {:error, {:forbidden, _}} =
             Tooling.call(
               member,
               "invite_workspace_member",
               write(c.team, %{"login" => outsider.login})
             )

    assert {:error, {:forbidden, _}} =
             Tooling.call(
               admin,
               "invite_workspace_member",
               write(c.team, %{"login" => outsider.login, "role" => "admin"})
             )

    assert {:ok, %{status: :member}} =
             Tooling.call(
               admin,
               "invite_workspace_member",
               write(c.team, %{"login" => outsider.login})
             )

    assert {:ok, %{role: :member}} = Workspaces.get(outsider, c.team.id)

    assert {:error, {:forbidden, _}} =
             Tooling.call(
               admin,
               "set_workspace_member_role",
               write(c.team, %{"user_id" => outsider.id, "role" => "admin"})
             )

    assert {:ok, _} =
             Tooling.call(
               c.p,
               "set_workspace_member_role",
               write(c.team, %{"user_id" => outsider.id, "role" => "admin"})
             )

    assert {:ok, %{role: :admin}} = Workspaces.get(outsider, c.team.id)

    assert {:error, {:forbidden, _}} =
             Tooling.call(
               admin,
               "remove_workspace_member",
               write(c.team, %{"user_id" => c.owner.id})
             )

    assert {:error, :not_found} =
             Tooling.call(
               c.p,
               "remove_workspace_member",
               write(c.team, %{"user_id" => insert_user().id})
             )

    assert {:error, {:conflict, "last_owner", _}} =
             Tooling.call(
               c.p,
               "set_workspace_member_role",
               write(c.team, %{"user_id" => c.owner.id, "role" => "member"})
             )

    assert {:ok, %{items: items}} =
             Tooling.call(member, "list_workspace_members", args(c.team, %{"limit" => 100}))

    assert Enum.any?(items, &(&1.id == outsider.id and &1.role == :admin))
    refute Enum.any?(items, &Map.has_key?(&1, :token_enc))
  end

  test "pending invitations can be listed and revoked with protected-owner rules", c do
    stub(Ravix.Config, :github, fn -> nil end)

    assert {:ok, %{status: :invited}} =
             Tooling.call(
               c.p,
               "invite_workspace_member",
               write(c.team, %{"login" => "new-person"})
             )

    assert {:ok, %{items: [invite]}} =
             Tooling.call(as(c.member), "list_workspace_invitations", args(c.team))

    assert invite.login == "new-person"
    assert Map.keys(invite) |> Enum.sort() == Enum.sort([:id, :login, :role, :created_at])

    assert {:error, {:forbidden, _}} =
             Tooling.call(
               as(c.admin),
               "revoke_workspace_invitation",
               write(c.team, %{"login" => "new-person"})
             )

    assert {:ok, _} =
             Tooling.call(
               c.p,
               "revoke_workspace_invitation",
               write(c.team, %{"login" => "new-person"})
             )

    assert {:ok, %{items: []}} = Tooling.call(c.p, "list_workspace_invitations", args(c.team))
  end

  test "removal and token revocation deny reads and mutation receipt replays", c do
    admin = as(c.admin)
    input = write(c.team, %{"name" => "Once"})
    assert {:ok, _} = Tooling.call(admin, "update_workspace", input)
    assert :ok = Workspaces.remove_member(c.owner, c.team.id, c.admin.id)
    assert {:error, :not_found} = Tooling.call(admin, "update_workspace", input)
    assert {:error, :not_found} = Tooling.call(admin, "get_workspace", args(c.team))

    assert {:error, :not_found} =
             WorkspaceTools.recheck(admin, "list_workspaces", %{}, %{items: [%{id: c.team.id}]})

    assert :ok = OAuth.disconnect(c.owner, c.p.grant.id)
    assert {:error, :unauthenticated} = Tooling.call(c.p, "get_workspace", args(c.team))

    assert {:error, :unauthenticated} =
             Tooling.call(c.p, "create_workspace", %{"name" => "No", "request_id" => "revoked"})
  end

  test "leave permits self-revocation and protects personal and last-owner workspaces", c do
    assert {:ok, _} = Tooling.call(as(c.member), "leave_workspace", write(c.team))
    assert {:error, :not_found} = Workspaces.get(c.member, c.team.id)

    assert {:error, {:conflict, "last_owner", _}} =
             Tooling.call(c.p, "leave_workspace", write(c.team))

    {:ok, personal} = Store.ensure_personal_workspace(c.owner)

    assert {:error, {:unprocessable, "personal", _}} =
             Tooling.call(c.p, "leave_workspace", write(personal))
  end

  test "sections and placements are personal, scoped, persistent and idempotent", c do
    project = insert_project(user: c.owner)
    Store.move_project(project.id, c.team.id)
    p = as(c.member)
    input = write(c.team, %{"name" => "Work"})
    assert {:ok, section} = Tooling.call(p, "create_workspace_section", input)
    assert {:ok, replay} = Tooling.call(p, "create_workspace_section", input)
    assert replay["id"] == section.id
    assert {:ok, %{items: []}} = Tooling.call(c.p, "list_workspace_sections", args(c.team))

    assert {:ok, _} =
             Tooling.call(
               p,
               "update_workspace_section",
               write(c.team, %{"section_id" => section.id, "collapsed" => true, "name" => "Later"})
             )

    assert {:ok, %{items: [%{collapsed: true}]}} =
             Tooling.call(p, "list_workspace_sections", args(c.team))

    assert {:ok, _} =
             Tooling.call(
               p,
               "move_workspace_placement",
               write(c.team, %{"project_id" => project.id, "section_id" => section.id})
             )

    assert {:ok, %{items: [%{project_id: id, section_id: sid}]}} =
             Tooling.call(p, "list_workspace_placements", args(c.team))

    assert id == project.id and sid == section.id

    assert {:ok, _} =
             Tooling.call(
               p,
               "move_workspace_placement",
               write(c.team, %{"project_id" => project.id, "section_id" => ""})
             )

    assert {:ok, %{items: []}} = Tooling.call(p, "list_workspace_placements", args(c.team))

    assert {:error, %Ecto.Changeset{}} =
             Tooling.call(p, "create_workspace_section", write(c.team, %{"name" => "Later"}))

    delete = write(c.team, %{"section_id" => section.id})
    assert {:ok, %{deleted: true}} = Tooling.call(p, "delete_workspace_section", delete)
    assert {:ok, %{"deleted" => true}} = Tooling.call(p, "delete_workspace_section", delete)
    assert {:ok, {[], %{}}} = Sections.list(c.member, c.team.id)
  end

  test "foreign sections/workspaces/projects and workspace mismatches cannot be mutated", c do
    {:ok, other} = Workspaces.create(c.owner, "Other")
    {:ok, own} = Sections.create(c.owner, other.id, %{name: "Other"})
    {:ok, theirs} = Sections.create(c.member, c.team.id, %{name: "Theirs"})
    project = insert_project(user: c.owner)
    Store.move_project(project.id, other.id)

    for section <- [own, theirs], name <- ~w(update_workspace_section delete_workspace_section) do
      assert {:error, :not_found} =
               Tooling.call(c.p, name, write(c.team, %{"section_id" => section.id}))
    end

    for section_id <- ["", own.id, theirs.id] do
      assert {:error, :not_found} =
               Tooling.call(
                 c.p,
                 "move_workspace_placement",
                 write(c.team, %{"project_id" => project.id, "section_id" => section_id})
               )
    end

    foreign = insert_user()
    {:ok, foreign_workspace} = Workspaces.create(foreign, "Foreign")

    assert {:error, :not_found} =
             Tooling.call(
               c.p,
               "create_workspace_section",
               write(foreign_workspace, %{"name" => "No"})
             )

    assert {:error, :not_found} =
             Tooling.call(
               c.p,
               "move_workspace_placement",
               write(c.team, %{
                 "project_id" => insert_project(user: foreign).id,
                 "section_id" => ""
               })
             )
  end

  test "stale placements no longer expose project IDs after project access is removed", c do
    {:ok, personal} = Store.ensure_personal_workspace(c.owner)
    stranger = insert_user()
    project = insert_project(user: stranger)
    share = insert_project_member(project, c.owner)
    {:ok, section} = Sections.create(c.owner, personal.id, %{name: "Shared"})
    {:ok, _} = Sections.move(c.owner, personal.id, project.id, section.id)
    assert {:ok, %{items: [_]}} = Tooling.call(c.p, "list_workspace_placements", args(personal))
    Repo.delete!(share)
    assert {:ok, %{items: []}} = Tooling.call(c.p, "list_workspace_placements", args(personal))

    assert {:error, :not_found} =
             WorkspaceTools.recheck(c.p, "list_workspace_placements", args(personal), %{
               items: [%{project_id: project.id}]
             })
  end

  test "repository connection visibility, proof, admission and failure preserve context rules",
       c do
    app =
      github(
        %{
          77 => %{account: "acme", repos: [repo(1, "acme/api"), repo(2, "acme/web")]},
          88 => %{account: "other", repos: []}
        },
        %{"owner" => [77]}
      )

    stub(Ravix.Config, :github, fn -> app end)

    owner =
      c.owner
      |> Ecto.Changeset.change(token_enc: Ravix.Crypto.encrypt("user-owner"))
      |> Repo.update!()

    p = as(owner)

    assert {:ok, %{items: [%{id: 77}]}} =
             Tooling.call(p, "list_available_workspace_installations", args(c.team))

    assert {:error, {:forbidden, _}} =
             Tooling.call(as(c.admin), "list_available_workspace_installations", args(c.team))

    assert {:error, {:forbidden, _}} =
             Tooling.call(
               as(c.admin),
               "add_workspace_installation",
               write(c.team, %{"installation_id" => 77})
             )

    assert {:error, {:unprocessable, "not_your_installation", _}} =
             Tooling.call(
               p,
               "add_workspace_installation",
               write(c.team, %{"installation_id" => 88})
             )

    add = write(c.team, %{"installation_id" => 77})

    assert {:ok, %{installation_id: 77, status: :active}} =
             Tooling.call(p, "add_workspace_installation", add)

    assert {:ok, %{"installation_id" => 77}} = Tooling.call(p, "add_workspace_installation", add)

    assert {:ok, %{items: []}} =
             Tooling.call(p, "list_available_workspace_installations", args(c.team))

    assert {:ok, %{items: [%{status: :active}]}} =
             Tooling.call(as(c.member), "list_workspace_connections", args(c.team))

    assert {:ok, first} =
             Tooling.call(
               as(c.member),
               "list_workspace_repositories",
               args(c.team, %{"limit" => 1})
             )

    assert first.next_cursor

    assert {:ok, last} =
             Tooling.call(
               p,
               "list_workspace_repositories",
               args(c.team, %{"limit" => 1, "after" => first.next_cursor})
             )

    assert length(last.items) == 1 and last.next_cursor == nil

    assert {:error, {:forbidden, _}} =
             Tooling.call(
               as(c.member),
               "add_workspace_repository",
               write(c.team, %{"full_name" => "acme/api"})
             )

    provisioning()

    assert {:ok, admitted} =
             Tooling.call(
               p,
               "add_workspace_repository",
               write(c.team, %{"full_name" => "acme/api"})
             )

    assert admitted.created

    assert {:ok, existing} =
             Tooling.call(
               as(c.member),
               "add_workspace_repository",
               write(c.team, %{"full_name" => "ACME/API"})
             )

    refute existing.created
    assert existing.project.id == admitted.project.id
    fail_page(1)

    assert {:ok, report} =
             Tooling.call(as(c.member), "refresh_workspace_repositories", write(c.team))

    assert report.failed_installations == %{items: [77], truncated: false}
    assert {:ok, %{items: cached}} = Tooling.call(p, "list_workspace_repositories", args(c.team))
    assert length(cached) == 2

    assert {:error, {:not_found, "repo_not_in_workspace", _}} =
             Tooling.call(
               p,
               "add_workspace_repository",
               write(c.team, %{"full_name" => "foreign/repo"})
             )
  end

  test "provider reads recheck removed membership and revoked grants before returning", c do
    app = github(%{77 => %{account: "acme", repos: []}}, %{"owner" => [77]})
    stub(Ravix.Config, :github, fn -> app end)

    owner =
      c.owner
      |> Ecto.Changeset.change(token_enc: Ravix.Crypto.encrypt("user-owner"))
      |> Repo.update!()

    p = as(owner)

    stub(Ravix.GitHub, :installations_for, fn _, _, :cached ->
      :ok = OAuth.disconnect(owner, p.grant.id)
      {:ok, []}
    end)

    assert {:error, :unauthenticated} =
             Tooling.call(p, "list_available_workspace_installations", args(c.team))
  end

  test "self-demotion succeeds and its receipt replays only with current membership and grant",
       c do
    second_owner = insert_user()

    for role <- ["admin", "member"] do
      {:ok, team} = Workspaces.create(c.owner, "Demote #{role}")
      :ok = Store.add_member(team.id, second_owner.id, :owner, c.owner.id)
      input = write(team, %{"user_id" => c.owner.id, "role" => role})
      assert {:ok, %{updated: true}} = Tooling.call(c.p, "set_workspace_member_role", input)
      assert {:ok, %{"updated" => true}} = Tooling.call(c.p, "set_workspace_member_role", input)
      assert {:ok, %{role: current}} = Workspaces.get(c.owner, team.id)
      assert Atom.to_string(current) == role

      assert {:error, {:forbidden, _}} =
               Tooling.call(
                 c.p,
                 "set_workspace_member_role",
                 write(team, %{"user_id" => c.owner.id, "role" => "owner"})
               )

      :ok = Workspaces.remove_member(second_owner, team.id, c.owner.id)
      assert {:error, :not_found} = Tooling.call(c.p, "set_workspace_member_role", input)
    end

    :ok = Store.add_member(c.team.id, second_owner.id, :owner, c.owner.id)
    input = write(c.team, %{"user_id" => c.owner.id, "role" => "admin"})
    assert {:ok, _} = Tooling.call(c.p, "set_workspace_member_role", input)
    :ok = OAuth.disconnect(c.owner, c.p.grant.id)
    assert {:error, :unauthenticated} = Tooling.call(c.p, "set_workspace_member_role", input)
  end

  test "leave and self-removal replay only own completed receipts after membership disappears",
       c do
    second_owner = insert_user()
    :ok = Store.add_member(c.team.id, second_owner.id, :owner, c.owner.id)
    self_remove = write(c.team, %{"user_id" => c.owner.id})
    assert {:ok, %{updated: true}} = Tooling.call(c.p, "remove_workspace_member", self_remove)
    assert {:ok, %{"updated" => true}} = Tooling.call(c.p, "remove_workspace_member", self_remove)

    assert {:error, :not_found} =
             Tooling.call(as(c.owner), "remove_workspace_member", self_remove)

    assert {:error, :not_found} = Tooling.call(c.p, "get_workspace", args(c.team))
    member = as(c.member)
    leave = write(c.team)
    assert {:ok, %{updated: true}} = Tooling.call(member, "leave_workspace", leave)
    assert {:ok, %{"updated" => true}} = Tooling.call(member, "leave_workspace", leave)
    assert {:error, :not_found} = Tooling.call(as(c.member), "leave_workspace", leave)
    assert {:error, :not_found} = Tooling.call(member, "leave_workspace", write(c.team))
    :ok = OAuth.disconnect(c.member, member.grant.id)
    assert {:error, :unauthenticated} = Tooling.call(member, "leave_workspace", leave)
    :ok = OAuth.disconnect(c.owner, c.p.grant.id)
    assert {:error, :unauthenticated} = Tooling.call(c.p, "remove_workspace_member", self_remove)
  end

  test "installation binding reports the persisted refresh state and timestamp", c do
    owner =
      c.owner
      |> Ecto.Changeset.change(token_enc: Ravix.Crypto.encrypt("user-owner"))
      |> Repo.update!()

    p = as(owner)

    for {status, attrs} <- [
          {:active, %{}},
          {:revoked, %{gone: true}},
          {:suspended, %{suspended: true}}
        ] do
      app = github(%{77 => Map.merge(%{account: "acme", repos: []}, attrs)}, %{"owner" => [77]})
      stub(Ravix.Config, :github, fn -> app end)
      {:ok, team} = Workspaces.create(owner, "Binding #{status}")

      assert {:ok, result} =
               Tooling.call(
                 p,
                 "add_workspace_installation",
                 write(team, %{"installation_id" => 77})
               )

      assert result.status == status
      assert %DateTime{} = result.refreshed_at

      assert {:ok, %{installations: [persisted]}} =
               Workspaces.Repositories.catalog(owner, team.id)

      assert result.refreshed_at == persisted.refreshed_at
      assert Workspaces.Installation.status(persisted) == status
    end
  end

  test "owned project moves preserve tracks and enforce target roles and repository uniqueness",
       c do
    {:ok, target} = Workspaces.create(c.owner, "Target")
    project = insert_project(user: c.owner, repo_full_name: "acme/api")
    Store.move_project(project.id, c.team.id)
    track = insert_track(project: project, visibility: :private)

    assert {:ok, targets} =
             Tooling.call(c.p, "list_workspace_move_targets", %{"project_id" => project.id})

    assert Enum.any?(targets.items, &(&1.id == target.id))
    assert targets.current_workspace_id == c.team.id

    assert {:error, :not_found} =
             Tooling.call(as(c.member), "list_workspace_move_targets", %{
               "project_id" => project.id
             })

    assert {:error, :not_found} =
             Tooling.call(
               as(c.admin),
               "move_workspace_project",
               write(c.team, %{"project_id" => project.id})
             )

    outsider = insert_user()
    {:ok, member_only} = Workspaces.create(outsider, "Member-only")
    :ok = Store.add_member(member_only.id, c.owner.id, :member, outsider.id)

    assert {:error, {:forbidden, _}} =
             Tooling.call(
               c.p,
               "move_workspace_project",
               write(member_only, %{"project_id" => project.id})
             )

    input = write(target, %{"project_id" => project.id})
    assert {:ok, %{workspace_id: id}} = Tooling.call(c.p, "move_workspace_project", input)
    assert id == target.id
    assert {:ok, %{"workspace_id" => ^id}} = Tooling.call(c.p, "move_workspace_project", input)
    assert Repo.get!(Ravix.Tracks.Track, track.id).project_id == project.id
    assert {:error, :not_found} = Projects.get(c.member, project.id)
    collision = insert_project(user: c.owner, repo_full_name: "acme/api")
    Store.move_project(collision.id, c.team.id)

    assert {:error, {:repository_taken, _}} =
             Tooling.call(
               c.p,
               "move_workspace_project",
               write(target, %{"project_id" => collision.id})
             )

    assert Repo.get!(Ravix.Projects.Project, collision.id).workspace_id == c.team.id
  end

  test "closed-track sidebar preferences persist personally and require project access", c do
    project = insert_project(user: c.owner)
    Store.move_project(project.id, c.team.id)
    member = as(c.member)

    assert {:ok, %{show: true}} =
             Tooling.call(
               member,
               "set_workspace_closed_visibility",
               write(c.team, %{"project_id" => project.id, "show" => true})
             )

    assert project.id in Sections.closed_shown(c.member)
    assert {:ok, %{items: [row]}} = Tooling.call(member, "list_workspace_projects", args(c.team))
    assert row.id == project.id and row.closed_tracks_visible
    assert row.owner_login == c.owner.login
    assert {:ok, %{items: [own_row]}} = Tooling.call(c.p, "list_workspace_projects", args(c.team))
    refute own_row.closed_tracks_visible

    assert {:ok, _} =
             Tooling.call(
               member,
               "set_workspace_closed_visibility",
               write(c.team, %{"project_id" => project.id, "show" => false})
             )

    refute project.id in Sections.closed_shown(c.member)
    stranger = insert_user()
    guest_project = insert_project(user: stranger)
    guest_track = insert_track(project: guest_project)
    insert_track_member(guest_track, c.owner)
    {:ok, personal} = Store.ensure_personal_workspace(c.owner)

    assert {:error, :not_found} =
             Tooling.call(
               c.p,
               "set_workspace_closed_visibility",
               write(personal, %{"project_id" => guest_project.id, "show" => true})
             )

    :ok = Workspaces.remove_member(c.owner, c.team.id, c.member.id)
    assert {:error, :not_found} = Tooling.call(member, "list_workspace_projects", args(c.team))
  end

  test "membership removed during a provider read is denied before results return", c do
    other_owner = insert_user()
    :ok = Store.add_member(c.team.id, other_owner.id, :owner, c.owner.id)
    app = github(%{})
    stub(Ravix.Config, :github, fn -> app end)

    owner =
      c.owner
      |> Ecto.Changeset.change(token_enc: Ravix.Crypto.encrypt("user-owner"))
      |> Repo.update!()

    p = as(owner)

    stub(Ravix.GitHub, :installations_for, fn _, _, :cached ->
      :ok = Workspaces.remove_member(other_owner, c.team.id, c.owner.id)
      {:ok, []}
    end)

    assert {:error, :not_found} =
             Tooling.call(p, "list_available_workspace_installations", args(c.team))
  end

  test "connect URL uses the browser's secured entry route and is restricted to managers", c do
    app = github(%{})
    stub(Ravix.Config, :github, fn -> app end)

    assert {:ok, %{url: url, browser_required: true}} =
             Tooling.call(as(c.admin), "get_workspace_connect_url", args(c.team))

    assert URI.parse(url).path == "/w/#{c.team.id}/github/connect"
    assert URI.parse(url).query == nil

    assert {:ok, %{url: configure}} =
             Tooling.call(c.p, "get_workspace_configure_url", args(c.team))

    assert URI.parse(configure).host == URI.parse(app.web_url).host

    assert {:error, {:forbidden, _}} =
             Tooling.call(as(c.member), "get_workspace_connect_url", args(c.team))

    assert {:error, :not_found} =
             Tooling.call(as(insert_user()), "get_workspace_connect_url", args(c.team))

    stub(Ravix.Config, :github, fn -> nil end)

    assert {:error, {:unconfigured, :github}} =
             Tooling.call(c.p, "get_workspace_configure_url", args(c.team))
  end
end

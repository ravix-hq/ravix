defmodule Ravix.Workspaces.RepositoriesTest do
  @moduledoc """
  ADR 0009 phase 4b: the workspace repository catalog and canonical
  admission. Multiple and revoked installations, one project from
  concurrent adds, normalization, renames and a rename collision, re-adding
  leading to the existing project, a member without personal GitHub access,
  legacy duplicates kept out, and other tenants' ids.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on, application-wide.
  """
  use Ravix.DataCase, async: false
  use Mimic

  import Ravix.Factory
  import Ravix.WorkspaceGitHubFixture

  alias Ravix.Fountain.FakeTransport
  alias Ravix.GitHubFake, as: GH
  alias Ravix.Projects.Project
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{CatalogRepo, Installation, Repositories, Store}

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    app =
      github(%{
        77 => %{account: "acme", repos: [repo(1, "Acme/API"), repo(2, "acme/web")]},
        88 => %{account: "tools", repos: [repo(3, "tools/cli"), repo(1, "Acme/API")]}
      })

    stub(Ravix.Config, :github, fn -> app end)

    # An owner with no personal GitHub token at all: everything here goes
    # through the installations.
    owner = insert_user(login: "owner", token_enc: nil, credential_set_id: "set-me")
    {:ok, team} = Workspaces.create(owner, "Acme")
    {:ok, a} = Store.bind_installation(team.id, 77, "acme", owner.id)
    {:ok, b} = Store.bind_installation(team.id, 88, "tools", owner.id)
    %{owner: owner, team: team, a: a, b: b}
  end

  defp names(%{repos: repos}), do: repos |> Enum.map(& &1.repo.full_name) |> Enum.sort()

  defp installed(workspace, github_id),
    do: Enum.find(Store.installations(workspace.id), &(&1.installation_id == github_id))

  describe "the catalog" do
    test "is every repository the live connections reach, once each, read without GitHub", ctx do
      assert {:ok, %{errors: [], renamed: [], collisions: []}} =
               Repositories.refresh(ctx.owner, ctx.team.id)

      _ = GH.requests()
      assert {:ok, catalog} = Repositories.catalog(ctx.owner, ctx.team.id)
      assert names(catalog) == ["Acme/API", "acme/web", "tools/cli"]
      assert %DateTime{} = catalog.refreshed_at
      # The page's read never reaches GitHub.
      assert GH.requests() == []
    end

    test "an uninstalled App and a suspended installation take their repositories out, with why",
         ctx do
      {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)

      github(%{
        77 => %{account: "acme", gone: true},
        88 => %{account: "tools", suspended: true, repos: [repo(3, "tools/cli")]}
      })

      assert {:ok, %{errors: []}} = Repositories.refresh(ctx.owner, ctx.team.id)
      assert {:ok, catalog} = Repositories.catalog(ctx.owner, ctx.team.id)
      assert catalog.repos == []

      assert %Installation{revoked_at: %DateTime{}, status_reason: gone} = installed(ctx.team, 77)
      assert gone =~ "uninstalled from @acme"

      assert %Installation{suspended_at: %DateTime{}, status_reason: held} =
               installed(ctx.team, 88)

      assert held =~ "suspended"
      assert Installation.status(installed(ctx.team, 88)) == :suspended

      # Unsuspended on GitHub: back on the next refresh.
      github(%{88 => %{account: "tools", repos: [repo(3, "tools/cli")]}})
      assert {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)
      assert {:ok, catalog} = Repositories.catalog(ctx.owner, ctx.team.id)
      assert names(catalog) == ["tools/cli"]
      assert Installation.status(installed(ctx.team, 88)) == :active
    end

    test "GitHub not answering keeps the last catalog and says which connection", ctx do
      {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)

      GH.install([
        {"GET", ~r{^/app/installations/\d+$}, {502, %{"message" => "Bad Gateway"}}}
      ])

      assert {:ok, %{errors: [{77, %Ravix.GitHub.Error{}}, {88, _}]}} =
               Repositories.refresh(ctx.owner, ctx.team.id)

      assert {:ok, catalog} = Repositories.catalog(ctx.owner, ctx.team.id)
      assert length(catalog.repos) == 3
    end

    test "any member reads it; a stranger and another tenant's id are not found", ctx do
      member = insert_user()
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)
      assert {:ok, _} = Repositories.catalog(member, ctx.team.id)
      assert {:ok, _} = Repositories.refresh(member, ctx.team.id)

      stranger = insert_user()
      {:ok, theirs} = Workspaces.create(stranger, "Theirs")
      assert {:error, :not_found} = Repositories.catalog(stranger, ctx.team.id)
      assert {:error, :not_found} = Repositories.refresh(stranger, ctx.team.id)
      assert {:error, :not_found} = Repositories.add(stranger, ctx.team.id, "acme/web")
      assert {:error, :not_found} = Repositories.catalog(ctx.owner, theirs.id)
      assert {:error, :not_found} = Repositories.add(ctx.owner, theirs.id, "acme/web")
    end
  end

  describe "admission" do
    setup ctx do
      {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)
      :ok
    end

    test "adding creates the one project through the installation; re-adding returns it", ctx do
      client = provisioning(1)

      assert {:ok, %{project: project, created: true}} =
               Repositories.add(ctx.owner, ctx.team.id, "acme/web")

      assert %Project{
               repo_full_name: "acme/web",
               normalized_repo_full_name: "acme/web",
               workspace_id: team_id,
               github_repo_id: 2,
               installation_id: 77,
               user_id: owner_id
             } = project

      assert team_id == ctx.team.id and owner_id == ctx.owner.id
      assert project.workspace_installation_id == ctx.a.id
      # The clone credential came from the installation, not a person.
      assert Enum.any?(FakeTransport.calls(client), &(&1.path == "/api/vaults/vault-1/secrets"))

      # RAV-13: however it is spelled, the repository leads to its project.
      for spelling <- ["acme/web", " ACME/Web\n", "Acme/WEB"] do
        assert {:ok, %{project: %{id: id}, created: false}} =
                 Repositories.add(ctx.owner, ctx.team.id, spelling)

        assert id == project.id
      end

      assert {:ok, catalog} = Repositories.catalog(ctx.owner, ctx.team.id)
      assert %{project: %{id: id}} = Enum.find(catalog.repos, &(&1.repo.full_name == "acme/web"))
      assert id == project.id
    end

    test "concurrent adds give one project", ctx do
      provisioning(1)
      parent = self()

      tasks =
        for _ <- 1..4 do
          Task.async(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> Repositories.add(ctx.owner, ctx.team.id, "tools/cli"))
          end)
        end

      pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
      Enum.each(pids, &send(&1, :go))
      results = Task.await_many(tasks, 15_000)

      assert [created] = for({:ok, %{created: true, project: p}} <- results, do: p)
      assert Enum.all?(results, &match?({:ok, %{project: %{id: id}}} when id == created.id, &1))

      assert Repo.aggregate(
               from(p in Project, where: p.workspace_id == ^ctx.team.id),
               :count
             ) == 1
    end

    test "the unique index is the last word: a lost race takes its machine back", ctx do
      client = provisioning(2, 1)
      {:ok, fresh} = Ravix.GitHub.repository(Ravix.Config.github(), 88, "tools/cli")

      admission = %{
        workspace_id: ctx.team.id,
        workspace_installation_id: ctx.b.id,
        installation_id: 88,
        repo: fresh
      }

      assert {:ok, %Project{}} = Ravix.Projects.admit(ctx.owner, admission)
      assert {:error, :exists} = Ravix.Projects.admit(ctx.owner, admission)
      assert Enum.any?(FakeTransport.calls(client), &(&1.path == "/api/agents/agent-2"))
    end

    test "a member reaches an existing project but only owners and admins create one", ctx do
      member = insert_user(token_enc: nil)
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)

      assert {:error, {:forbidden, _}} = Repositories.add(member, ctx.team.id, "acme/web")

      provisioning(1)
      {:ok, %{project: project}} = Repositories.add(ctx.owner, ctx.team.id, "acme/web")

      # No personal GitHub access at all, and the repository is theirs to use.
      assert {:ok, %{project: %{id: id}, created: false}} =
               Repositories.add(member, ctx.team.id, "acme/web")

      assert id == project.id
    end

    test "an admin with no personal GitHub token admits through the installation", ctx do
      admin = insert_user(token_enc: nil, credential_set_id: "set-me")
      :ok = Store.add_member(ctx.team.id, admin.id, :admin, ctx.owner.id)
      provisioning(1)

      assert {:ok, %{created: true, project: %{user_id: admin_id}}} =
               Repositories.add(admin, ctx.team.id, "tools/cli")

      assert admin_id == admin.id
    end

    test "a repository no live connection reaches is refused", ctx do
      assert {:error, {:not_found, "repo_not_in_workspace", _}} =
               Repositories.add(ctx.owner, ctx.team.id, "someone/else")

      assert {:error, {:unprocessable, "no_repo", _}} =
               Repositories.add(ctx.owner, ctx.team.id, "  ")

      # Still in the cached catalog, but GitHub no longer grants it.
      github(%{77 => %{account: "acme", repos: []}, 88 => %{account: "tools", repos: []}})

      assert {:error, {:not_found, "repo_not_in_workspace", _}} =
               Repositories.add(ctx.owner, ctx.team.id, "acme/web")
    end

    test "a rename on GitHub renames the project instead of duplicating it", ctx do
      provisioning(1)
      {:ok, %{project: project}} = Repositories.add(ctx.owner, ctx.team.id, "acme/web")

      github(%{
        77 => %{account: "acme", repos: [repo(1, "Acme/API"), repo(2, "acme/website")]},
        88 => %{account: "tools", repos: [repo(3, "tools/cli")]}
      })

      Ravix.Hub.subscribe(project.id)
      assert {:ok, %{renamed: ["acme/website"]}} = Repositories.refresh(ctx.owner, ctx.team.id)
      assert_receive {:hub, %Ravix.Hub.Event{name: :settings}}

      assert %Project{repo_full_name: "acme/website", normalized_repo_full_name: "acme/website"} =
               Repo.get!(Project, project.id)

      assert {:ok, %{project: %{id: id}, created: false}} =
               Repositories.add(ctx.owner, ctx.team.id, "acme/website")

      assert id == project.id

      assert Repo.aggregate(from(p in Project, where: p.workspace_id == ^ctx.team.id), :count) ==
               1
    end

    test "a rename found at admission leads to the existing project", ctx do
      provisioning(1)
      {:ok, %{project: project}} = Repositories.add(ctx.owner, ctx.team.id, "tools/cli")

      # Renamed on GitHub, and the catalog has read the new name, but the
      # project has not followed yet: admission finds it by GitHub's id.
      github(%{88 => %{account: "tools", repos: [repo(3, "tools/cli2")]}})

      Repo.update_all(from(r in CatalogRepo, where: r.github_repo_id == 3),
        set: [full_name: "tools/cli2", normalized_repo_full_name: "tools/cli2"]
      )

      assert {:ok, %{project: %{id: id} = found, created: false}} =
               Repositories.add(ctx.owner, ctx.team.id, "tools/cli2")

      assert id == project.id
      assert found.repo_full_name == "tools/cli2"
    end

    test "a rename onto a name another project holds is a collision, left alone", ctx do
      provisioning(2)
      {:ok, %{project: web}} = Repositories.add(ctx.owner, ctx.team.id, "acme/web")
      {:ok, %{project: cli}} = Repositories.add(ctx.owner, ctx.team.id, "tools/cli")

      # tools/cli was transferred and renamed to the name acme/web's project holds.
      github(%{
        77 => %{account: "acme", repos: [repo(1, "Acme/API"), repo(2, "acme/web")]},
        88 => %{account: "tools", repos: [repo(3, "Acme/Web")]}
      })

      assert {:ok, %{collisions: ["Acme/Web"]}} = Repositories.refresh(ctx.owner, ctx.team.id)
      assert Repo.get!(Project, cli.id).repo_full_name == "tools/cli"
      assert Repo.get!(Project, web.id).repo_full_name == "acme/web"
    end

    test "a project moved in without a GitHub id is claimed by name and keeps it", ctx do
      moved = insert_project(user: ctx.owner, repo_full_name: "acme/web")
      Store.move_project(moved.id, ctx.team.id)

      assert {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)
      assert Repo.get!(Project, moved.id).github_repo_id == 2

      assert {:ok, %{project: %{id: id}, created: false}} =
               Repositories.add(ctx.owner, ctx.team.id, "acme/web")

      assert id == moved.id
    end

    test "a legacy duplicate is never the workspace's project and never offered", ctx do
      first =
        insert_project(
          user: ctx.owner,
          repo_full_name: "acme/web",
          created_at: ~U[2026-01-01 00:00:00Z]
        )

      later = insert_project(user: ctx.owner, repo_full_name: "acme/web")
      {:ok, _} = Store.mark_legacy_duplicate(later.id, first.id)
      Store.move_project(later.id, ctx.team.id)

      assert {:ok, catalog} = Repositories.catalog(ctx.owner, ctx.team.id)
      assert %{project: nil} = Enum.find(catalog.repos, &(&1.repo.full_name == "acme/web"))

      provisioning(1)

      assert {:ok, %{project: project, created: true}} =
               Repositories.add(ctx.owner, ctx.team.id, "acme/web")

      refute project.id == later.id
    end
  end
end

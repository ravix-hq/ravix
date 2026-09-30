defmodule Ravix.Workspaces.BackingInstallationsTest do
  @moduledoc """
  RAV-69: a workspace's GitHub connections include the installations its
  own projects already clone through, and nothing else, without anybody
  pressing Connect GitHub.

  Projects that reached a workspace before phase 4b's catalog did (moved,
  assigned, seeded) carried only their own `installation_id`, so the
  workspace said "No GitHub account is connected yet" while its tracks
  worked. The backfill step, and the attach on every later move, connect
  exactly those installations: never one with no project there, never a
  personal account's to a team workspace, never one somebody revoked.
  """
  use Ravix.DataCase, async: true

  alias Ravix.Projects.Project
  alias Ravix.Workspaces.{Backfill, Installation, Store, Workspace}

  defp workspace!(attrs) do
    %Workspace{} |> Workspace.changeset(Map.new(attrs)) |> Repo.insert!()
  end

  defp team!(owner),
    do:
      workspace!(
        name: "Acme #{System.unique_integer()}",
        kind: :team,
        created_by_user_id: owner.id
      )

  defp personal!(user),
    do: workspace!(name: user.login, kind: :personal, personal_user_id: user.id)

  # A project already in `workspace`, as a move or the seed left it: its
  # installation, and no connection row.
  defp project_in!(workspace, owner, repo, installation_id, attrs \\ []) do
    project =
      insert_project(
        Keyword.merge(
          [user: owner, repo_full_name: repo, installation_id: installation_id],
          attrs
        )
      )

    1 = Store.move_project(project.id, workspace.id)
    Repo.get!(Project, project.id)
  end

  # `move_project/2` attaches on its own; this undoes that, so a test can
  # start from the rows an earlier release left.
  defp forget_connections(workspace),
    do: Repo.delete_all(from i in Installation, where: i.workspace_id == ^workspace.id)

  defp connections(workspace),
    do: workspace.id |> Store.installations() |> Enum.map(&{&1.installation_id, &1.account_login})

  setup do
    owner = insert_user(login: "owner-#{System.unique_integer([:positive])}")
    %{owner: owner, team: team!(owner)}
  end

  test "a workspace whose projects predate the catalog is connected by the backfill", ctx do
    project = project_in!(ctx.team, ctx.owner, "ravix-hq/ravix", 77)
    forget_connections(ctx.team)
    assert Store.installations(ctx.team.id) == []

    assert %{installations: attached} = Backfill.run()
    assert attached >= 1

    assert [%Installation{} = connection] = Store.installations(ctx.team.id)
    assert connection.installation_id == 77
    assert connection.account_login == "ravix-hq"
    assert connection.connected_by_user_id == project.user_id
    assert Installation.status(connection) == :active
  end

  test "running the backfill twice attaches nothing more", ctx do
    project_in!(ctx.team, ctx.owner, "acme/api", 77)
    project_in!(ctx.team, ctx.owner, "acme/web", 77)
    forget_connections(ctx.team)

    Backfill.run(batch_size: 1)
    assert connections(ctx.team) == [{77, "acme"}]

    assert Backfill.run().installations == 0
    assert Backfill.run(batch_size: 1).installations == 0
    assert connections(ctx.team) == [{77, "acme"}]
  end

  test "an installation with no live project in the workspace is never attached", ctx do
    other = team!(ctx.owner)
    project_in!(other, ctx.owner, "elsewhere/api", 55)
    project_in!(ctx.team, ctx.owner, "acme/old", 66, archived_at: DateTime.utc_now())
    gone = project_in!(ctx.team, ctx.owner, "acme/gone", 88)

    Repo.update_all(from(p in Project, where: p.id == ^gone.id),
      set: [deletion_requested_at: DateTime.utc_now()]
    )

    # A project that never joined a workspace brings nothing anywhere.
    insert_project(user: ctx.owner, repo_full_name: "loose/repo", installation_id: 99)
    Enum.each([ctx.team, other], &forget_connections/1)

    Backfill.run()

    assert connections(ctx.team) == []
    assert connections(other) == [{55, "elsewhere"}]
    refute Repo.exists?(from i in Installation, where: i.installation_id == 99)
  end

  test "a revoked connection stays revoked", ctx do
    project_in!(ctx.team, ctx.owner, "acme/api", 77)
    forget_connections(ctx.team)
    {:ok, bound} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
    :ok = Store.record_refresh(bound, :revoked, "The Ravix GitHub App was uninstalled.", [])

    Backfill.run()

    assert [connection] = Store.installations(ctx.team.id)
    assert Installation.status(connection) == :revoked
  end

  test "a personal account's installation is never attached to a team workspace", ctx do
    person = insert_user(login: "Jo-Person")
    project_in!(ctx.team, person, "jo-person/dotfiles", 31)
    mine = personal!(person)
    project_in!(mine, person, "jo-person/notes", 31)
    Enum.each([ctx.team, mine], &forget_connections/1)

    Backfill.run()

    assert connections(ctx.team) == []
    assert connections(mine) == [{31, "jo-person"}]
  end

  test "moving a project into a workspace brings its installation", ctx do
    project = insert_project(user: ctx.owner, repo_full_name: "acme/api", installation_id: 77)

    assert {:ok, _moved} =
             Store.move_owned_project(project.id, ctx.owner.id, nil, ctx.team.id)

    assert connections(ctx.team) == [{77, "acme"}]

    # A second project on the same installation adds no second row.
    again = insert_project(user: ctx.owner, repo_full_name: "acme/web", installation_id: 77)
    assert {:ok, _} = Store.move_owned_project(again.id, ctx.owner.id, nil, ctx.team.id)
    assert connections(ctx.team) == [{77, "acme"}]
  end

  test "the personal assignment brings the installation into the owner's own workspace", ctx do
    mine = personal!(ctx.owner)
    project = insert_project(user: ctx.owner, repo_full_name: "acme/api", installation_id: 77)

    assert Store.assign_personal(project.id, mine.id) == :moved
    assert connections(mine) == [{77, "acme"}]
  end
end

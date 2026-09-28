defmodule Ravix.WorkspacePermissionRaceTest do
  @moduledoc """
  A share racing a workspace removal leaves no permission row, in either
  order (ADR 0009 phase 3b).

  Real transactions, so the two sides contend for the membership lock the
  way two requests do: outside the SQL sandbox, on committed rows this test
  deletes afterwards. Each side holds its transaction open until the test
  lets it commit, which is what makes the order deterministic.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Ravix.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.People.Store, as: PeopleStore
  alias Ravix.Repo
  alias Ravix.Tracks.TrackPermission
  alias Ravix.Workspaces.{Membership, Store}

  setup do
    Sandbox.unboxed_run(Repo, fn ->
      owner = insert_user()
      member = insert_user()
      {:ok, workspace} = Store.ensure_personal_workspace(owner)

      Repo.insert!(%Membership{
        workspace_id: workspace.id,
        user_id: member.id,
        role: :member,
        created_at: DateTime.utc_now()
      })

      project = insert_project(user: owner)

      Repo.update_all(where(Ravix.Projects.Project, id: ^project.id),
        set: [workspace_id: workspace.id]
      )

      track = insert_track(project: project, visibility: :private, created_by: owner.id)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(where(TrackPermission, track_id: ^track.id))
          Repo.delete!(track)
          Repo.delete!(Repo.get!(Ravix.Projects.Project, project.id))
          Repo.delete!(member)
          Repo.delete!(owner)
        end)
      end)

      %{owner: owner, member: member, workspace: workspace, track: track}
    end)
  end

  # Run `fun` in a transaction on its own process, and hold it open after
  # `fun` returns until told to commit. Reports `{tag, result}` once committed.
  defp held(tag, fun) do
    parent = self()

    hold = fn ->
      result = fun.()
      send(parent, {:holding, tag})

      receive do
        :commit -> result
      end
    end

    run = fn ->
      {:ok, result} = Repo.transaction(hold)
      send(parent, {tag, result})
    end

    pid = spawn_link(fn -> Sandbox.unboxed_run(Repo, run) end)

    assert_receive {:holding, ^tag}, 5_000
    pid
  end

  # Run `fun` on its own process, outside any transaction of ours.
  defp racing(tag, fun) do
    parent = self()
    spawn_link(fn -> Sandbox.unboxed_run(Repo, fn -> send(parent, {tag, fun.()}) end) end)
  end

  defp rows(ctx) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.all(where(TrackPermission, track_id: ^ctx.track.id, user_id: ^ctx.member.id))
    end)
  end

  test "a share that waits on an open removal finds the member gone", ctx do
    removal =
      held(:removed, fn ->
        Store.revoke_membership(ctx.workspace.id, ctx.member.id, ctx.owner.id)
      end)

    racing(:shared, fn ->
      PeopleStore.add_permission(ctx.track.id, ctx.member.id, ctx.workspace.id, ctx.owner.id)
    end)

    # Blocked on the removal's lock, not answered from a stale read.
    refute_receive {:shared, _}, 300
    send(removal, :commit)

    assert_receive {:removed, {:ok, _}}, 5_000
    assert_receive {:shared, {:error, :not_workspace_member}}, 5_000
    assert rows(ctx) == []
  end

  test "a removal that waits on an open share deletes the row it wrote", ctx do
    share =
      held(:shared, fn ->
        PeopleStore.add_permission(ctx.track.id, ctx.member.id, ctx.workspace.id, ctx.owner.id)
      end)

    racing(:removed, fn ->
      Store.revoke_membership(ctx.workspace.id, ctx.member.id, ctx.owner.id)
    end)

    refute_receive {:removed, _}, 300
    send(share, :commit)

    assert_receive {:shared, :ok}, 5_000
    assert_receive {:removed, {:ok, _}}, 5_000
    assert rows(ctx) == []
  end
end

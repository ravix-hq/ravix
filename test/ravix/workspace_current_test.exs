defmodule Ravix.WorkspaceCurrentTest do
  @moduledoc """
  The current workspace (ADR 0009 follow-up): who may choose one, the
  default, the fallback when a membership ends, and where each reachable
  project sits relative to it.

  Not async: the tests flip `RAVIX_WORKSPACE_ACCESS`, which is application-wide.
  """
  use Ravix.DataCase, async: false

  import Ravix.Factory

  alias Ravix.{Accounts, Projects, Repo, Workspaces}
  alias Ravix.Workspaces.Store

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    me = insert_user(login: "me")
    {:ok, personal} = Store.ensure_personal_workspace(me)
    %{me: me, personal: personal}
  end

  test "the default is the first team workspace, else the personal one", ctx do
    assert {:ok, %{workspace: %{id: id}, role: :owner}} = Workspaces.current(ctx.me)
    assert id == ctx.personal.id

    {:ok, first} = Workspaces.create(ctx.me, "First")
    {:ok, _second} = Workspaces.create(ctx.me, "Second")
    assert {:ok, %{workspace: %{id: id}}} = Workspaces.current(ctx.me)
    assert id == first.id

    assert {:error, :not_found} = Workspaces.current(insert_user())
  end

  test "a chosen workspace is remembered, and a lapsed membership falls back", ctx do
    boss = insert_user(login: "boss")
    {:ok, theirs} = Workspaces.create(boss, "Theirs")
    :ok = Store.add_member(theirs.id, ctx.me.id, :member, boss.id)

    assert {:ok, me} = Accounts.put_current_workspace(ctx.me, theirs.id)
    assert Repo.reload!(me).current_workspace_id == theirs.id
    assert {:ok, %{workspace: %{id: id}, role: :member}} = Workspaces.current(me)
    assert id == theirs.id

    :ok = Workspaces.remove_member(boss, theirs.id, ctx.me.id)
    assert {:ok, %{workspace: %{id: id}}} = Workspaces.current(me)
    assert id == ctx.personal.id
    # Choosing it again is refused, as for anybody outside it.
    assert {:error, :not_found} = Accounts.put_current_workspace(me, theirs.id)
    assert {:error, :not_found} = Accounts.put_current_workspace(me, Ecto.UUID.generate())
    assert {:error, :not_found} = Accounts.put_current_workspace(me, nil)
  end

  test "partition: own workspaces by membership, the rest in the personal one", ctx do
    {:ok, team} = Workspaces.create(ctx.me, "Team")
    friend = insert_user(login: "friend")
    stranger = insert_user(login: "stranger")
    {:ok, elsewhere} = Workspaces.create(stranger, "Elsewhere")

    mine = insert_project(user: ctx.me, name: "Mine")
    in_team = insert_project(user: ctx.me, name: "InTeam")
    Store.move_project(in_team.id, team.id)
    shared = insert_project(user: friend, name: "Shared")
    insert_project_member(shared, ctx.me)
    # A legacy grant on a project in a workspace this person is not in.
    far = insert_project(user: stranger, name: "Far")
    Store.move_project(far.id, elsewhere.id)
    insert_project_member(far, ctx.me)
    track_only = insert_project(user: friend, name: "TrackOnly")
    insert_track_member(insert_track(project: track_only), ctx.me)

    views = Projects.list(ctx.me, include_machine: false)
    listed = Workspaces.list(ctx.me)
    names = fn views -> views |> Enum.map(& &1.name) |> Enum.sort() end

    personal = Workspaces.partition(ctx.me, ctx.personal, listed, views)
    assert names.(personal.current) == ["Mine"]
    assert names.(personal.shared) == ["Far", "Shared", "TrackOnly"]
    assert names.(personal.other) == ["InTeam"]

    in_team_scope = Workspaces.partition(ctx.me, team, listed, views)
    assert names.(in_team_scope.current) == ["InTeam"]
    assert in_team_scope.shared == []
    assert names.(in_team_scope.other) == ["Far", "Mine", "Shared", "TrackOnly"]

    # Unscoped: everything is current.
    assert Workspaces.partition(ctx.me, nil, listed, views).current == views

    view = &Enum.find(views, fn v -> v.id == &1.id end)
    assert Workspaces.home(ctx.me, listed, view.(in_team)) == team.id
    assert Workspaces.home(ctx.me, listed, view.(mine)) == ctx.personal.id
    assert Workspaces.home(ctx.me, listed, view.(far)) == ctx.personal.id
  end

  test "a membership of somebody else's personal workspace is not one's own", ctx do
    host = insert_user(login: "host")
    {:ok, hosts} = Store.ensure_personal_workspace(host)
    :ok = Store.add_member(hosts.id, ctx.me.id, :member, host.id)
    hosted = insert_project(user: host, name: "Hosted")
    Store.move_project(hosted.id, hosts.id)

    assert {:ok, %{workspace: %{id: id}}} = Workspaces.current(ctx.me)
    assert id == ctx.personal.id

    listed = Workspaces.list(ctx.me)
    views = Projects.list(ctx.me, include_machine: false)

    assert %{current: [], other: [%{id: other}]} =
             Workspaces.partition(ctx.me, ctx.personal, listed, views)

    assert other == hosted.id
    assert Workspaces.home(ctx.me, listed, hd(views)) == hosts.id
  end

  test "somebody with no personal workspace keeps every project in view" do
    loner = insert_user(login: "loner")
    {:ok, team} = Workspaces.create(loner, "Team")
    legacy = insert_project(user: loner, name: "Legacy")
    listed = Workspaces.list(loner)
    views = Projects.list(loner, include_machine: false)

    assert %{current: [%{id: id}], shared: [], other: []} =
             Workspaces.partition(loner, team, listed, views)

    assert id == legacy.id
    assert Workspaces.home(loner, listed, hd(views)) == nil
  end

  test "with the switch off there is no current workspace and none can be chosen", ctx do
    Application.put_env(:ravix, :workspace_access, false)
    assert {:error, :not_found} = Workspaces.current(ctx.me)
    assert {:error, :not_found} = Accounts.put_current_workspace(ctx.me, ctx.personal.id)
    assert Repo.reload!(ctx.me).current_workspace_id == nil
  end
end

defmodule Ravix.TracksRailTest do
  use Ravix.DataCase, async: true
  import Mimic
  alias Ravix.{Accounts.Access, QueryCount, Tracks}
  alias Ravix.Fountain.{Client, FakeTransport}

  setup :verify_on_exit!

  test "bulk discovery scopes open tracks in one query regardless of project count" do
    viewer = insert_user()
    owned = insert_project(user: viewer)
    member = insert_project()
    shared = insert_project()
    foreign = insert_project()
    archived = insert_project(user: viewer, archived_at: DateTime.utc_now())
    insert_project_member(member, viewer)
    a = insert_track(project: owned)
    b = insert_track(project: member)
    c = insert_track(project: shared)
    insert_track_member(c, viewer)
    insert_track(project: shared)
    insert_track(project: foreign)
    insert_track(project: archived)
    insert_track(project: owned, closed_at: DateTime.utc_now())

    private =
      insert_track(
        project: owned,
        visibility: :private,
        created_by: insert_user().id,
        sandbox_layout: :dedicated
      )

    own_private =
      insert_track(
        project: member,
        visibility: :private,
        created_by: viewer.id,
        sandbox_layout: :dedicated
      )

    invited_private =
      insert_track(
        project: shared,
        visibility: :private,
        created_by: insert_user().id,
        sandbox_layout: :dedicated
      )

    insert_track_member(invited_private, viewer)
    assert {:error, :not_found} = Access.track_access(viewer, private.id)

    revoked =
      insert_track(
        project: member,
        visibility: :private,
        created_by: viewer.id,
        sandbox_layout: :dedicated
      )

    revoked
    |> Ecto.Changeset.change(creator_revoked_at: DateTime.utc_now())
    |> Ravix.Repo.update!()

    assert {:error, :not_found} = Access.track_access(viewer, revoked.id)
    ids = Enum.map([owned, member, shared, foreign, archived], & &1.id)
    {rows, queries} = QueryCount.count(fn -> Access.open_tracks(viewer, ids) end)
    assert length(queries) == 1

    assert MapSet.new(rows, fn {track, _} -> track.id end) ==
             MapSet.new([a.id, b.id, c.id, own_private.id, invited_private.id])

    assert Access.open_tracks(insert_user(), ids) == []
    tracks = Tracks.list_many(viewer, ids)
    assert Enum.sort(Map.keys(tracks)) == Enum.sort([owned.id, member.id, shared.id])
    assert MapSet.new(tracks[shared.id], & &1.id) == MapSet.new([c.id, invited_private.id])

    for project <- [owned, member, shared] do
      assert {:ok, expected} = Tracks.list(viewer, project.id)
      assert tracks[project.id] == expected
    end
  end

  test "closed tracks join the same one query under the same visibility, with creator avatars" do
    viewer = insert_user(avatar_url: "https://avatars.example/viewer.png")
    other = insert_user()
    owned = insert_project(user: viewer)
    member = insert_project()
    insert_project_member(member, viewer)
    closed_at = DateTime.utc_now()
    open = insert_track(project: owned, created_by: viewer.id, created_by_login: viewer.login)
    closed = insert_track(project: owned, closed_at: closed_at, created_by: other.id)
    closed_member = insert_track(project: member, closed_at: closed_at)
    legacy = insert_track(project: owned, created_by_login: viewer.login)

    # The project owner never sees another person's private track, open or closed.
    foreign_private =
      insert_track(
        project: owned,
        visibility: :private,
        created_by: other.id,
        sandbox_layout: :dedicated,
        closed_at: closed_at
      )

    own_private =
      insert_track(
        project: member,
        visibility: :private,
        created_by: viewer.id,
        sandbox_layout: :dedicated,
        closed_at: closed_at
      )

    revoked =
      insert_track(
        project: member,
        visibility: :private,
        created_by: viewer.id,
        sandbox_layout: :dedicated,
        closed_at: closed_at
      )
      |> Ecto.Changeset.change(creator_revoked_at: closed_at)
      |> Ravix.Repo.update!()

    ids = [owned.id, member.id]

    {rows, queries} =
      QueryCount.count(fn -> Access.open_tracks(viewer, ids, closed: Map.new(ids, &{&1, 20})) end)

    assert length(queries) == 1
    found = MapSet.new(rows, fn {track, _} -> track.id end)

    assert found ==
             MapSet.new([open.id, closed.id, closed_member.id, legacy.id, own_private.id])

    refute foreign_private.id in found
    refute revoked.id in found

    only_owned = Access.open_tracks(viewer, ids, closed: %{owned.id => 20})

    assert MapSet.new(only_owned, fn {track, _} -> track.id end) ==
             MapSet.new([open.id, closed.id, legacy.id])

    {row, _} = Enum.find(rows, fn {track, _} -> track.id == open.id end)
    assert row.creator_avatar_url == viewer.avatar_url
    {row, _} = Enum.find(rows, fn {track, _} -> track.id == legacy.id end)
    assert row.creator_avatar_url == nil

    assert Access.created_by?(viewer, open)
    assert Access.created_by?(viewer, legacy)
    refute Access.created_by?(viewer, closed)

    tracks = Tracks.list_many(viewer, ids, closed: %{owned.id => 20})

    assert tracks[owned.id] |> Enum.filter(&(&1.status == :closed)) |> Enum.map(& &1.id) == [
             closed.id
           ]

    refute Map.has_key?(tracks, member.id)
    assert {:ok, listed} = Tracks.list(viewer, member.id, closed: 20)
    assert MapSet.new(listed, & &1.id) == MapSet.new([closed_member.id, own_private.id])
  end

  test "closed tracks are capped per project to the most recently closed, still in one query" do
    viewer = insert_user()
    other = insert_user()
    busy = insert_project(user: viewer)
    quiet = insert_project(user: viewer)
    open = insert_track(project: busy)
    base = ~U[2026-09-01 00:00:00.000000Z]

    closed =
      for n <- 1..25 do
        insert_track(project: busy, closed_at: DateTime.add(base, n, :hour))
      end

    # Newer than all of them, but another person's private track: it is not
    # shown and must not take one of the places.
    insert_track(
      project: busy,
      visibility: :private,
      created_by: other.id,
      sandbox_layout: :dedicated,
      closed_at: DateTime.add(base, 100, :hour)
    )

    quiet_closed = insert_track(project: quiet, closed_at: base)
    ids = [busy.id, quiet.id]

    {rows, queries} =
      QueryCount.count(fn ->
        Access.open_tracks(viewer, ids, closed: %{busy.id => 20, quiet.id => 20})
      end)

    assert length(queries) == 1
    found = Enum.map(rows, fn {track, _} -> track.id end)
    newest = closed |> Enum.reverse() |> Enum.take(20) |> Enum.map(& &1.id)
    assert MapSet.new(found) == MapSet.new([open.id, quiet_closed.id | newest])

    # A larger limit is the next page; open tracks are never capped.
    more = Access.open_tracks(viewer, ids, closed: %{busy.id => 21})
    assert length(more) == 22
    refute quiet_closed.id in Enum.map(more, fn {track, _} -> track.id end)
  end

  test "machine states come from the rail's own rows, with no Fountain request per row" do
    viewer = insert_user()
    project = insert_project(user: viewer)
    now = DateTime.utc_now()
    opened = [opened_at: now, project: project]

    rows = [
      idle: insert_track([sandbox_layout: :dedicated, sandbox_state: :ready] ++ opened),
      asleep:
        insert_track(
          [sandbox_layout: :dedicated, sandbox_state: :ready, sandbox_suspended_at: now] ++
            opened
        ),
      restarting:
        insert_track(
          [
            sandbox_layout: :dedicated,
            sandbox_state: :provisioning,
            sandbox_action: :rebuild,
            sandbox_stage: "creating",
            setup_state: "pending"
          ] ++ opened
        ),
      closing: insert_track([sandbox_layout: :dedicated, sandbox_state: :closing] ++ opened),
      legacy: insert_track([sandbox_suspended_at: now] ++ opened)
    ]

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}}
      ])

    stub(Ravix.Fountain, :client, fn -> client end)
    project_id = project.id
    %{^project_id => views} = Tracks.list_many(viewer, [project_id])
    states = Map.new(views, &{&1.id, Tracks.MachineState.of(&1).state})

    for {state, row} <- rows,
        do: assert(states[row.id] == if(state == :legacy, do: :idle, else: state))

    # One list for the project, whatever the number of rows: no sandbox, file
    # or conversation read was made to decide any row's state.
    assert [%{path: "/api/conversations"}] = FakeTransport.calls(client)
  end

  test "a failed provider presentation is isolated to its project" do
    viewer = insert_user()
    broken = insert_project(user: viewer)
    healthy = insert_project(user: viewer)
    insert_track(project: broken)
    track = insert_track(project: healthy)

    stub(Ravix.Fountain, :client, fn ->
      Client.new("https://example.test", "fixture")
    end)

    stub(Ravix.MachineCache, :conversations, fn _client, project, _opts ->
      if project.id == broken.id do
        raise "provider failed"
      else
        {:ok, []}
      end
    end)

    result = Tracks.list_many(viewer, [broken.id, healthy.id])
    assert Enum.map(result[healthy.id], & &1.id) == [track.id]
    assert result[broken.id] == {:error, :unavailable}
  end
end

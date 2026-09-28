defmodule Ravix.TracksRailTest do
  use Ravix.DataCase, async: true
  import Mimic
  alias Ravix.{Accounts.Access, QueryCount, Tracks}
  alias Ravix.Fountain.Client

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
    ids = Enum.map([owned, member, shared, foreign, archived], & &1.id)
    {rows, queries} = QueryCount.count(fn -> Access.open_tracks(viewer, ids) end)
    assert length(queries) == 1
    assert MapSet.new(rows, fn {track, _} -> track.id end) == MapSet.new([a.id, b.id, c.id])
    assert Access.open_tracks(insert_user(), ids) == []
    tracks = Tracks.list_many(viewer, ids)
    assert Enum.sort(Map.keys(tracks)) == Enum.sort([owned.id, member.id, shared.id])
    assert Enum.map(tracks[shared.id], & &1.id) == [c.id]

    for project <- [owned, member, shared] do
      assert {:ok, expected} = Tracks.list(viewer, project.id)
      assert tracks[project.id] == expected
    end
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
    refute Map.has_key?(result, broken.id)
  end
end

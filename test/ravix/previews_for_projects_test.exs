defmodule Ravix.PreviewsForProjectsTest do
  # `Previews.for_projects/2`: the previews a person may see, by project, for
  # Home's counts and a project page's list. Read only, and scoped as the
  # tracks themselves are.
  use Ravix.DataCase, async: true, group: :preview_ports
  import Mimic

  alias Ravix.{Previews, Repo}

  setup :verify_on_exit!

  setup do
    stub(Ravix.Config, :sprites, fn ->
      %Ravix.Config.Sprites{token: "test", base_url: "http://sprites.test"}
    end)

    stub(Ravix.Config, :previews, fn ->
      %Ravix.Config.Previews{domain: "preview.localhost", protocol: :http, public_port: ":5183"}
    end)

    stub(Ravix.Config, :fountain, fn ->
      %Ravix.Config.Fountain{url: "http://fountain.test", key: "test"}
    end)

    :ok
  end

  test "lists the previews up or coming up on tracks this person may see, by project" do
    owner = insert_user()
    member = insert_user()
    project = insert_project(user: owner)
    insert_project_member(project, member)

    ready = insert_track(project: project)
    insert_preview(track: ready, state: :ready, desired: :running)
    starting = insert_track(project: project)
    insert_preview(track: starting, state: :starting, desired: :running)
    stopped = insert_track(project: project)
    insert_preview(track: stopped, state: :stopped)
    closed = insert_track(project: project, closed_at: DateTime.utc_now())
    insert_preview(track: closed, state: :ready, desired: :running)
    private = insert_track(project: project, visibility: "private", created_by: owner.id)
    insert_preview(track: private, state: :ready, desired: :running)

    elsewhere = insert_track()
    insert_preview(track: elsewhere, state: :ready, desired: :running)

    found = Previews.for_projects(member, [project.id, elsewhere.project_id])

    # Only the project the member is in: the other one's preview is not theirs.
    assert Map.keys(found) == [project.id]

    assert found[project.id] |> Enum.map(& &1.track_id) |> Enum.sort() ==
             Enum.sort([ready.id, starting.id])

    # The creator sees their private track's preview too.
    owner_ids = Previews.for_projects(owner, [project.id])[project.id] |> Enum.map(& &1.track_id)
    assert private.id in owner_ids

    # A track with no preview row gets none from reading: unlike `status/2`,
    # nothing is created.
    bare = insert_track(project: insert_project(user: owner))
    count = Repo.aggregate(Ravix.Previews.Preview, :count)
    assert Previews.for_projects(owner, [bare.project_id]) == %{}
    assert Repo.aggregate(Ravix.Previews.Preview, :count) == count
  end

  test "is empty where previews are not available" do
    stub(Ravix.Config, :previews, fn -> nil end)
    owner = insert_user()
    track = insert_track(project: insert_project(user: owner))
    insert_preview(track: track, state: :ready, desired: :running)

    assert Previews.for_projects(owner, [track.project_id]) == %{}
    assert Previews.for_projects(owner, []) == %{}
  end
end

defmodule Ravix.Tracks.FountainTitlesTest do
  # Not async: the conversation list is loaded by `Ravix.MachineCache` in a
  # task of its own, which only a shared sandbox lets reach the database.
  use Ravix.DataCase, async: false

  alias Ravix.Fountain.FakeTransport
  alias Ravix.Hub
  alias Ravix.Hub.Event
  alias Ravix.MachineCache
  alias Ravix.Tracks
  alias Ravix.Tracks.{Store, Thread, Track}

  setup do
    owner = insert_user(login: "owner")
    project = insert_project(user: owner)
    :ok = Hub.subscribe(project.id)
    {:ok, owner: owner, project: project}
  end

  # A track whose title the first prompt already gave, as `Titling` leaves it.
  defp titled_track(project, slug) do
    track =
      insert_track(
        project: project,
        conversation_id: "c-#{slug}-#{System.unique_integer([:positive])}",
        slug: slug,
        title: "ravix/#{slug}",
        branch: "ravix/#{slug}"
      )

    Repo.update_all(from(t in Track, where: t.id == ^track.id),
      set: [title: "Pull Latest Main", title_source: :auto]
    )

    Repo.update_all(from(t in Thread, where: t.id == ^track.id),
      set: [title: "Pull Latest Main", title_source: :auto]
    )

    Repo.get!(Track, track.id)
  end

  defp listing(project, conversations) do
    FakeTransport.client([
      {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
       {200, [], %{data: conversations}}}
    ])
  end

  defp conversation(track, fields),
    do: Map.merge(%{id: track.conversation_id, status: "idle", sandbox_id: "sb"}, fields)

  test "a harness title on the list retitles an automatic thread and its track", ctx do
    track = titled_track(ctx.project, "crewe")

    client =
      listing(ctx.project, [
        conversation(track, %{title: "Main branch pull", title_source: "harness"})
      ])

    assert {:ok, [_]} = MachineCache.conversations(client, ctx.project)

    id = track.id
    assert_receive {:hub, %Event{name: :tracks, track_id: ^id}}, 2_000
    assert %Track{title: "Main branch pull", title_source: :auto} = Repo.get!(Track, id)
    assert %Thread{title: "Main branch pull", title_source: :auto} = Store.thread(id)

    # Read again from the memo: no second load, no second write.
    assert {:ok, [_]} = MachineCache.conversations(client, ctx.project)
    refute_received {:hub, %Event{name: :tracks}}
  end

  test "a person's rename is never replaced", ctx do
    track = titled_track(ctx.project, "manual")
    :ok = Tracks.rename(ctx.owner, track.id, "Ledger cleanup")
    :ok = Tracks.rename_thread(ctx.owner, track.id, track.id, "My thread")
    id = track.id
    assert_receive {:hub, %Event{name: :tracks, track_id: ^id}}
    assert_receive {:hub, %Event{name: :tracks, track_id: ^id}}

    client =
      listing(ctx.project, [
        conversation(track, %{title: "Main branch pull", title_source: "harness"})
      ])

    assert {:ok, [_]} = MachineCache.conversations(client, ctx.project)

    assert %Track{title: "Ledger cleanup", title_source: :manual} = Repo.get!(Track, id)
    assert %Thread{title: "My thread", title_source: :manual} = Store.thread(id)
    refute_received {:hub, %Event{name: :tracks}}
  end

  test "a conversation with no title, or the owner's, keeps the prompt's title", ctx do
    untitled = titled_track(ctx.project, "untitled")
    owned = titled_track(ctx.project, "owned")
    opened = titled_track(ctx.project, "opened")

    client =
      listing(ctx.project, [
        conversation(untitled, %{title: nil}),
        conversation(owned, %{title: "Owner's name", title_source: "user"}),
        # A conversation opened before this release, by a Fountain that does
        # not send `title_source`: the branch Ravix sent as its title.
        conversation(opened, %{title: "ravix/opened"})
      ])

    assert {:ok, [_, _, _]} = MachineCache.conversations(client, ctx.project)

    for track <- [untitled, owned, opened] do
      assert Repo.get!(Track, track.id).title == "Pull Latest Main"
      assert Store.thread(track.id).title == "Pull Latest Main"
    end

    refute_received {:hub, %Event{name: :tracks}}
  end
end

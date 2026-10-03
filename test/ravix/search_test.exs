defmodule Ravix.SearchTest do
  use Ravix.DataCase, async: true
  import Mimic
  alias Ravix.{Repo, Search}
  alias Ravix.Search.{Entry, Index}
  alias Ravix.Tracks.{Reply, Thread, Track}
  alias Ravix.Tracks.Transcript
  alias Ravix.TranscriptFixture, as: TF

  setup :verify_on_exit!

  setup do
    owner = insert_user()
    project = insert_project(user: owner, name: "Orchid", repo_full_name: "acme/orchid")

    track =
      insert_track(project: project, title: "Orchid track", conversation_id: "conv-#{project.id}")

    %{owner: owner, project: project, track: track}
  end

  defp events(turn, prompt, answer, cursor \\ 1) do
    [
      TF.stage(cursor, "started")
      |> Map.merge(%{
        "turn_id" => turn,
        "blocks" => [%{"kind" => "prompt", "body" => prompt}],
        "ts" => "2026-10-03T19:00:00Z"
      }),
      TF.output(cursor + 1, TF.text(answer), turn),
      TF.output(cursor + 2, TF.thought("hiddenreasoning"), turn),
      TF.output(cursor + 3, TF.call("secrettool"), turn),
      TF.output(cursor + 4, TF.result("secrettool"), turn),
      TF.stage(cursor + 5, "completed")
      |> Map.merge(%{"turn_id" => turn, "ts" => "2026-10-03T19:01:00Z"})
    ]
  end

  defp search(user, q, params \\ %{}) do
    assert {:ok, page} = Search.run(user, Map.put(params, "q", q))
    page
  end

  test "project/track names and pending human text are searched without attachments", ctx do
    insert_prompt(
      track: ctx.track,
      user: ctx.owner,
      body: %{"prompt" => "Orchid pending human", "images" => [%{"data" => "secretattachment"}]}
    )

    assert Enum.sort(Enum.map(search(ctx.owner, "Orchid").results, & &1.kind)) == [
             "project",
             "queued_prompt",
             "track"
           ]

    assert [%{kind: "queued_prompt"}] = search(ctx.owner, "pending").results
    assert search(ctx.owner, "secretattachment").results == []
    assert search(ctx.owner, "gho_secret").results == []
  end

  test "two completed turns survive newest reply replacement and ingestion is idempotent", ctx do
    first = events("first", "firsthuman", "firstassistant")
    second = events("second", "secondhuman", "secondassistant", 20)
    Reply.record(ctx.track.conversation_id, first, "claude")
    Reply.record(ctx.track.conversation_id, second, "claude")
    Reply.record(ctx.track.conversation_id, first, "claude")
    assert Repo.aggregate(Entry, :count) == 4
    assert [%{kind: "prompt", turn_id: "first"}] = search(ctx.owner, "firsthuman").results

    assert [%{kind: "assistant", turn_id: "first", thread_id: id, conversation_id: conv}] =
             search(ctx.owner, "firstassistant").results

    assert id == ctx.track.id
    assert conv == ctx.track.conversation_id
    assert [%{turn_id: "second"}] = search(ctx.owner, "secondassistant").results
    assert search(ctx.owner, "hiddenreasoning").results == []
    assert search(ctx.owner, "secrettool").results == []
    assert search(ctx.owner, "defmodule Example").results == []
  end

  test "a reread with older or truncated data cannot overwrite indexed text", ctx do
    Index.record(
      ctx.track.conversation_id,
      events("same", "human", "latest complete words", 20),
      "claude"
    )

    Index.record(ctx.track.conversation_id, events("same", "human", "stale", 1), "claude")
    Index.record(ctx.track.conversation_id, events("same", "human", "latest", 20), "claude")
    assert [%{excerpt: text}] = search(ctx.owner, "complete").results
    assert text =~ "latest complete words"
  end

  test "page backfill includes archived conversations, but not pending turns", ctx do
    Repo.update_all(from(t in Thread, where: t.id == ^ctx.track.id),
      set: [previous_conversation_ids: ["oldconv"]]
    )

    page = Transcript.page(events("oldturn", "oldhuman", "oldassistant"), "claude", %{})
    turns = Enum.map(page.turns, &%{&1 | conversation_id: "oldconv"})
    assert :ok = Index.persist(turns)
    assert [%{conversation_id: "oldconv"}] = search(ctx.owner, "oldassistant").results
    assert :ok = Index.persist(Enum.map(turns, &%{&1 | settled?: false}))

    assert :ok =
             Index.record(
               "unrelated-conversation",
               events("unknown", "no", "unrelatedtext"),
               "claude"
             )

    assert search(ctx.owner, "unrelatedtext").results == []
  end

  test "supervised page hook writes selected text", ctx do
    page = Transcript.page(events("backfill", "pagehuman", "pageassistant"), "claude", %{})

    page = %{
      page
      | turns: Enum.map(page.turns, &%{&1 | conversation_id: ctx.track.conversation_id})
    }

    parent = self()

    :telemetry.attach(
      "search-index-#{ctx.track.id}",
      [:ravix, :repo, :query],
      fn _, _, metadata, _ ->
        if String.starts_with?(metadata.query, "INSERT INTO \"ravix\".\"search_entries\""),
          do: send(parent, :indexed)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("search-index-#{ctx.track.id}") end)
    assert :ok = Index.note(page)
    assert_receive :indexed
    assert [%{kind: "assistant"}] = search(ctx.owner, "pageassistant").results
  end

  test "track-only share admits its content and filter, never private siblings/project results",
       ctx do
    guest = insert_user()
    seat = insert_track_member(ctx.track, guest)

    sibling =
      insert_track(
        project: ctx.project,
        title: "Orchid private sibling",
        visibility: :private,
        created_by: ctx.owner.id,
        conversation_id: "privateconv"
      )

    Index.record(
      sibling.conversation_id,
      events("private", "privatetext", "privateanswer"),
      "claude"
    )

    Index.record(
      ctx.track.conversation_id,
      events("shared", "sharedhuman", "sharedanswer"),
      "claude"
    )

    assert Enum.map(search(guest, "Orchid").results, & &1.kind) == ["track"]
    assert search(guest, "privateanswer").results == []

    assert [%{kind: "assistant"}] =
             search(guest, "sharedanswer", %{"project" => ctx.project.id}).results

    assert {:ok, filters} = Search.filters(guest, %{})
    assert Enum.map(filters.tracks, & &1.id) == [ctx.track.id]
    assert Enum.map(filters.projects, & &1.id) == [ctx.project.id]
    page = search(guest, "sharedanswer")
    Repo.delete!(seat)
    assert search(guest, "sharedanswer").results == []
    assert {:ok, %{results: []}} = Search.revalidate(guest, page)
    assert {:ok, %{projects: [], tracks: []}} = Search.filters(guest, %{})
  end

  test "project membership grants project-visible tracks only and revoked/unrelated users see nothing",
       ctx do
    member = insert_user()
    membership = insert_project_member(ctx.project, member)

    insert_track(
      project: ctx.project,
      title: "Orchid private",
      visibility: :private,
      created_by: ctx.owner.id
    )

    assert Enum.sort(Enum.map(search(member, "Orchid").results, & &1.kind)) == [
             "project",
             "track"
           ]

    Repo.delete!(membership)
    assert search(member, "Orchid").results == []
    assert search(insert_user(), "Orchid").results == []
    assert search(member, "Orchid", %{"track" => ctx.track.id}).results == []
  end

  test "workspace flag and revoked live membership are honored", ctx do
    member = insert_user()

    w =
      %Ravix.Workspaces.Workspace{}
      |> Ravix.Workspaces.Workspace.changeset(%{name: "Team", kind: :team})
      |> Repo.insert!()

    m =
      %Ravix.Workspaces.Membership{}
      |> Ravix.Workspaces.Membership.changeset(%{
        workspace_id: w.id,
        user_id: member.id,
        role: :member
      })
      |> Repo.insert!()

    Repo.update_all(from(p in Ravix.Projects.Project, where: p.id == ^ctx.project.id),
      set: [workspace_id: w.id]
    )

    private =
      insert_track(
        project: ctx.project,
        title: "Orchid private",
        visibility: :private,
        created_by: ctx.owner.id
      )

    %Ravix.Tracks.TrackPermission{}
    |> Ravix.Tracks.TrackPermission.changeset(%{
      track_id: private.id,
      user_id: member.id,
      workspace_id: w.id
    })
    |> Repo.insert!()

    stub(Ravix.Config, :workspace_access?, fn -> false end)
    assert search(member, "Orchid").results == []
    stub(Ravix.Config, :workspace_access?, fn -> true end)
    assert length(search(member, "Orchid").results) == 3
    Repo.update!(Ecto.Changeset.change(m, revoked_at: DateTime.utc_now()))
    assert search(member, "Orchid").results == []
  end

  test "deterministic pagination and project/track filtering", ctx do
    at = ~U[2026-10-03 19:00:00.000000Z]

    tracks =
      for _ <- 1..25, do: insert_track(project: ctx.project, title: "paginated", created_at: at)

    first = search(ctx.owner, "paginated")
    second = search(ctx.owner, "paginated", %{"page" => "2"})
    assert length(first.results) == 20
    assert first.has_more
    assert length(second.results) == 5
    refute second.has_more
    ids = Enum.map(first.results ++ second.results, & &1.id)
    assert ids == Enum.sort(Enum.map(tracks, & &1.id))
    assert first == search(ctx.owner, "paginated")

    assert [%{id: id}] =
             search(ctx.owner, "paginated", %{
               "project" => ctx.project.id,
               "track" => hd(tracks).id
             }).results

    assert id == hd(tracks).id
    assert search(ctx.owner, "paginated", %{"project" => "someone-else"}).results == []
  end

  test "empty, punctuation, injection attempts and invalid queries are bounded", ctx do
    for q <- ["", "   ", "!!!", "' OR 1=1; --", "%_", "<&>"] do
      assert search(ctx.owner, q).results == []
    end

    for params <- [
          %{"q" => String.duplicate("x", 501)},
          %{"q" => <<0>>},
          %{"q" => []},
          %{"page" => "0"},
          %{"page" => "1001"},
          %{"page" => "2no"},
          %{"page" => 3}
        ] do
      assert {:error, {:unprocessable, _, _}} = Search.run(ctx.owner, params)
    end

    assert {:ok, _} = Search.filters(ctx.owner, %{"project" => "missing"})
  end

  test "archived and deleting projects hide their search content", ctx do
    Index.record(
      ctx.track.conversation_id,
      events("turn", "retainedhuman", "retainedassistant"),
      "claude"
    )

    Repo.update_all(from(p in Ravix.Projects.Project, where: p.id == ^ctx.project.id),
      set: [archived_at: DateTime.utc_now()]
    )

    assert search(ctx.owner, "retainedassistant").results == []
    assert {:ok, %{projects: [], tracks: []}} = Search.filters(ctx.owner, %{})
  end

  test "each role is bounded and deletes follow thread removal", ctx do
    Index.record(
      ctx.track.conversation_id,
      events("big", String.duplicate("p", 70_000), String.duplicate("a", 70_000)),
      "claude"
    )

    assert Enum.all?(Repo.all(Entry), &(String.length(&1.text) == 65_536))
    Repo.delete_all(from t in Track, where: t.id == ^ctx.track.id)
    assert Repo.aggregate(Entry, :count) == 0
  end
end

defmodule Ravix.Tracks.TranscriptHistoryTest do
  use Ravix.DataCase, async: false
  use Ravix.TraceCase, async: false
  import Mimic
  alias Ravix.Fountain
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Tracks
  alias Ravix.Tracks.{Thread, Transcript}
  alias Ravix.TranscriptFixture, as: Fixture

  setup :verify_on_exit!

  test "7,000-event forward-only fallback renders ten newest turns and never refetches earlier chunks" do
    owner = insert_user()

    track =
      insert_track(
        project: insert_project(user: owner, runtime: "codex"),
        conversation_id: "long"
      )

    log = events(35, 200)
    base = "/api/conversations/long"
    pages = log |> Enum.chunk_every(1000) |> Enum.with_index()

    routes =
      Enum.map(pages, fn {events, index} ->
        query = if index == 0, do: %{}, else: %{after: to_string(index * 1000)}

        {%{
           method: "GET",
           path: base <> "/events",
           query: Map.merge(%{limit: "1000", blocks: "true", prompts: "true"}, query)
         },
         {200, [], %{data: events, meta: %{has_more: index < 6, next_cursor: (index + 1) * 1000}}}}
      end)

    records = [%{"id" => "t26", "image_count" => 2}, %{"id" => "t1", "image_count" => 1}]

    client =
      FakeTransport.client(
        routes ++ [{%{method: "GET", path: base <> "/turns"}, {200, [], %{data: records}}}]
      )

    stub(Fountain, :client, fn -> client end)
    assert {:ok, page} = Tracks.events(owner, track.id)

    full =
      log
      |> Transcript.page("codex", %{})
      |> Transcript.with_images(Fountain.Shapes.turns(records))

    assert comparable(page.turns) == comparable(Enum.take(full.turns, -10))
    assert page.oldest_event_id == 5001
    assert page.last_event_id == 7000
    assert Transcript.add_event(page, hd(log)) == page
    assert Transcript.add_event(page, Enum.at(log, 200)) == page
    # Honest limitation: Fountain #2531 must land before this can become 1–2.
    assert Enum.count(FakeTransport.calls(client), &(&1.path == base <> "/events")) == 7
    assert_receive {:span, initial = span(name: "tracks.events")}
    assert attributes(initial)["ravix.event_pages"] == 7
    assert attributes(initial)["ravix.events_fetched"] == 7000
    calls = FakeTransport.calls(client)
    assert {:error, :not_found} = Tracks.earlier_events(insert_user(), track.id, page.history)
    assert {:ok, page} = earlier(owner, track.id, page)
    assert comparable(page.turns) == comparable(Enum.take(full.turns, -20))
    assert page.last_event_id == 7000
    assert_receive {:span, span(name: "tracks.events.earlier")}
    assert {:ok, page} = earlier(owner, track.id, page)
    assert {:ok, page} = earlier(owner, track.id, page)
    refute Transcript.History.more?(page.history)
    assert comparable(page.turns) == comparable(full.turns)
    assert page.oldest_event_id == 1
    assert {:ok, ^page} = earlier(owner, track.id, page)
    assert FakeTransport.calls(client) == calls
    page = Transcript.add_event(page, Fixture.output(7001, Fixture.text("live"), "live"))
    assert List.last(page.turns).id == "live"
    assert page.last_event_id == 7001
  end

  test "archives are read newest first on demand, with scoped IDs and an unchanged live cursor" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project, conversation_id: "new")
    thread = Repo.get!(Thread, track.id)
    Repo.update!(Ecto.Changeset.change(thread, previous_conversation_ids: ["old", "middle"]))
    client = Fountain.Client.new("https://fountain.test", "key")
    stub(Fountain, :client, fn -> client end)
    stub(Fountain, :turns, fn _, _ -> {:ok, []} end)

    expect(Fountain, :events, fn _, "new", [prompts: true] ->
      {:ok, [Fixture.output(100, Fixture.text("new"), "new-turn")]}
    end)

    assert {:ok, page} = Tracks.events(owner, track.id)
    assert Enum.map(page.turns, & &1.id) == ["new-turn"]
    other = insert_track(project: project, conversation_id: "other")
    assert {:error, :not_found} = Tracks.earlier_events(owner, other.id, page.history)
    forged = %{page | history: %{page.history | conversations: ["someone-else"]}}
    assert {:error, :not_found} = Tracks.earlier_events(owner, track.id, forged.history)
    expect(Fountain, :events, fn _, "middle", [prompts: true] -> {:error, :offline} end)
    assert {:error, :offline} = earlier(owner, track.id, page)

    expect(Fountain, :events, fn _, "middle", [prompts: true] ->
      {:ok, [Fixture.output(50, Fixture.text("middle"), "middle-turn")]}
    end)

    assert {:ok, page} = earlier(owner, track.id, page)

    expect(Fountain, :events, fn _, "old", [prompts: true] ->
      {:ok, [Fixture.output(1, Fixture.text("old"), "old-turn")]}
    end)

    assert {:ok, page} = earlier(owner, track.id, page)
    assert Enum.map(page.turns, & &1.id) == ["old-turn", "middle-turn", "new-turn"]
    assert page.conversation_id == "new"
    assert page.last_event_id == 100
    assert page.oldest_conversation_id == "old"

    assert {:error, :not_found} =
             Tracks.earlier_events(owner, track.id, Transcript.empty("codex"))
  end

  test "chunks keep interleaved turns and pending lifecycle events equivalent to a full build" do
    log = events(25, 3)
    # A turn resumes across what would otherwise have been a page boundary.
    log =
      log ++
        [
          Fixture.output(76, Fixture.text("resumed"), "t10"),
          Map.put(Fixture.output(77, Fixture.text("orphan")), "turn_id", nil)
        ]

    history = Transcript.History.new(log, [], "c", [], :fixture)
    chunks = Enum.map(history.chunks, &Transcript.page(&1, "codex", %{}))

    combined =
      Enum.reduce(chunks, Transcript.empty("codex"), fn chunk, page ->
        Transcript.prepend_history(page, chunk)
      end)

    assert comparable(Enum.reject(combined.turns, &String.starts_with?(&1.id, "pending"))) ==
             comparable(
               Enum.reject(Transcript.page(log, "codex", %{}).turns, &(&1.id == "pending"))
             )

    assert List.last(combined.turns).blocks ==
             List.last(Transcript.page(log, "codex", %{}).turns).blocks
  end

  test "unbound setup output from separate conversations has distinct stable identities" do
    make = fn conversation, text ->
      page =
        Transcript.page([Map.put(Fixture.output(1, Fixture.text(text)), "turn_id", nil)], "codex")

      %{
        page
        | conversation_id: conversation,
          turns: Enum.map(page.turns, &%{&1 | conversation_id: conversation})
      }
    end

    page = make.("new", "new setup")
    old = make.("old", "old setup")
    page = Transcript.prepend_history(page, old)
    assert Enum.map(page.turns, & &1.id) == ["old:pending", "pending"]
    assert Transcript.prepend_history(page, old) == page
    assert Enum.map(page.turns, fn turn -> hd(turn.blocks).body end) == ["old setup", "new setup"]
  end

  test "early setup and late turn-less runs do not join the entire conversation into one chunk" do
    unbound = fn id, body -> Map.put(Fixture.output(id, Fixture.text(body)), "turn_id", nil) end
    middle = Enum.map(events(35, 3), &Map.update!(&1, "id", fn id -> id + 2 end))

    log =
      [unbound.(1, "setup "), unbound.(2, "ready")] ++
        middle ++
        [unbound.(108, "late "), unbound.(109, "notice")]

    history = Transcript.History.new(log, [], "c", [], :fixture)
    assert length(history.chunks) == 4
    [latest | _] = history.chunks
    assert length(latest) < 40
    newest = Transcript.page(latest, "codex", %{})
    assert Enum.any?(newest.turns, &(&1.id == "t35"))
    refute Enum.any?(newest.turns, &(&1.id == "t1"))

    combined =
      Enum.reduce(history.chunks, Transcript.empty("codex"), fn events, page ->
        Transcript.prepend_history(page, Transcript.page(events, "codex", %{}))
      end)

    assert Enum.map(combined.turns, & &1.id) ==
             ["pending:1"] ++ Enum.map(1..35, &"t#{&1}") ++ ["pending:108"]

    assert hd(hd(combined.turns).blocks).body == "setup ready"
    assert hd(List.last(combined.turns).blocks).body == "late notice"
  end

  defp earlier(owner, track_id, page) do
    request = Transcript.History.request(page.history)

    with {:ok, chunk} <- Tracks.earlier_events(owner, track_id, request) do
      # The response contains only the newly parsed chunk, never the held tail
      # or the remaining raw chunks for this conversation.
      assert length(chunk.turns) <= 10
      if page.history.chunks != [], do: assert(chunk.history.chunks == [])
      chunk = %{chunk | history: Transcript.History.advance(page.history, chunk.history)}
      {:ok, Transcript.prepend_history(page, chunk)}
    end
  end

  defp comparable(turns), do: Enum.map(turns, &Map.from_struct(%{&1 | conversation_id: nil}))

  defp events(count, size) do
    Enum.flat_map(1..count, fn turn ->
      first = (turn - 1) * size + 1

      opened =
        Fixture.stage(first, "started")
        |> Map.put("turn_id", "t#{turn}")
        |> Map.put("blocks", [%{"kind" => "prompt", "body" => "Prompt #{turn}"}])

      [
        opened
        | Enum.map(
            (first + 1)..(first + size - 1),
            &Fixture.output(&1, Fixture.text("text "), "t#{turn}")
          )
      ]
    end)
  end
end

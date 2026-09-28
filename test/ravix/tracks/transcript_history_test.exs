defmodule Ravix.Tracks.TranscriptHistoryTest do
  use Ravix.DataCase, async: false
  use Ravix.TraceCase, async: false
  import Mimic
  alias Ravix.Fountain
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Tracks
  alias Ravix.Tracks.{Settlement, Thread, Transcript}
  alias Ravix.TranscriptFixture, as: Fixture

  setup :verify_on_exit!

  # Classification pages back on its own, off the read path; its requests are
  # `Ravix.Tracks.TranscriptLoadTest`'s business. Here each read hands it the
  # page it rendered.
  setup do
    parent = self()

    stub(Settlement, :scan, fn _client, history, events, _runtime, _binding ->
      send(parent, {:scan, history.conversation_id, Enum.map(events, & &1["id"])})
      :ok
    end)

    :ok
  end

  test "a 7,000-event conversation opens with one newest-first request; Load earlier reads one page each" do
    owner = insert_user()

    track =
      insert_track(
        project: insert_project(user: owner, runtime: "codex"),
        conversation_id: "long"
      )

    # 350 turns of 20 events: a 200-event page is the newest ten, whole.
    log = sparse(350, 20)
    base = "/api/conversations/long"
    [first | earlier] = Fixture.desc_routes(base <> "/events", log)
    records = [%{"id" => "t26", "image_count" => 2}, %{"id" => "t345", "image_count" => 1}]
    turns = {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: records}}}
    client = FakeTransport.client([first, turns | earlier])
    stub(Fountain, :client, fn -> client end)

    assert {:ok, page} = Tracks.events(owner, track.id)

    full =
      log
      |> Transcript.page("codex", %{})
      |> Transcript.with_images(Fountain.Shapes.turns(records))

    assert [%{query: query}] = event_calls(client, base)

    assert %{"order" => "desc", "whole_turns" => "true", "prompts" => "true", "limit" => "200"} =
             query

    refute Map.has_key?(query, "before")
    assert comparable(page.turns) == comparable(Enum.take(full.turns, -10))
    {_, {200, [], body}} = first
    assert page.last_event_id == body["page"]["newest_cursor"]
    assert page.last_event_id == List.last(log)["id"]
    assert_receive {:scan, "long", scanned}
    assert scanned == body["data"] |> Enum.map(& &1["id"]) |> Enum.reverse()
    assert_receive {:span, initial = span(name: "tracks.events")}
    assert attributes(initial)["ravix.event_pages"] == 1
    assert attributes(initial)["ravix.events_fetched"] == 200
    assert attributes(initial)["ravix.events_order"] == "desc"

    assert {:error, :not_found} = Tracks.earlier_events(insert_user(), track.id, page.history)
    assert length(event_calls(client, base)) == 1
    assert_receive {:span, refused = span(name: "tracks.events.earlier")}
    assert attributes(refused)["ravix.event_pages"] == 0

    page =
      Enum.reduce(Enum.with_index(earlier, 2), page, fn {{%{query: query}, _}, count}, page ->
        assert {:ok, page} = earlier(owner, track.id, page)
        calls = event_calls(client, base)
        assert length(calls) == count
        assert List.last(calls).query == query
        assert_receive {:span, span = span(name: "tracks.events.earlier")}
        assert attributes(span)["ravix.event_pages"] == 1
        assert attributes(span)["ravix.events_order"] == "desc"
        assert page.last_event_id == List.last(log)["id"]
        page
      end)

    refute Transcript.History.more?(page.history)
    assert comparable(page.turns) == comparable(full.turns)
    assert page.oldest_event_id == hd(log)["id"]
    calls = FakeTransport.calls(client)
    assert {:ok, ^page} = earlier(owner, track.id, page)
    assert FakeTransport.calls(client) == calls
    live = List.last(log)["id"] + 3
    page = Transcript.add_event(page, Fixture.output(live, Fixture.text("live"), "live"))
    assert List.last(page.turns).id == "live"
    assert page.last_event_id == live
  end

  test "one huge turn is a single whole page far past the limit, rendered once" do
    owner = insert_user()

    track =
      insert_track(
        project: insert_project(user: owner, runtime: "codex"),
        conversation_id: "huge"
      )

    # Three short turns, then a 5,000-event one: Fountain's ceiling exactly.
    log = sparse(3, 10, prefix: "s") ++ sparse(1, 5000, prefix: "huge", from: 30)
    base = "/api/conversations/huge"
    [first, older] = Fixture.desc_routes(base <> "/events", log)
    {_, {200, [], body}} = first
    assert length(body["data"]) == 5000 and body["page"]["turn_split"] == false

    client =
      FakeTransport.client([
        first,
        {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: []}}},
        older
      ])

    stub(Fountain, :client, fn -> client end)
    assert {:ok, page} = Tracks.events(owner, track.id)
    assert [%{query: %{"limit" => "200"}}] = event_calls(client)
    assert [%{id: "huge1"} = huge] = page.turns
    assert length(huge.events) == 5000
    full = full("huge", log)
    assert comparable(page.turns) == comparable(Enum.take(full.turns, -1))
    assert page.last_event_id == List.last(log)["id"]
    assert_receive {:span, initial = span(name: "tracks.events")}
    assert attributes(initial)["ravix.events_fetched"] == 5000
    # The page is not held raw: only the cursor remains.
    assert page.history.held == [] and is_integer(page.history.before)

    assert {:ok, page} = earlier(owner, track.id, page)
    assert length(event_calls(client)) == 2
    refute Transcript.History.more?(page.history)
    assert comparable(page.turns) == comparable(full.turns)
  end

  test "mostly turn-less output renders after three pages, and Load earlier reads the rest" do
    owner = insert_user()

    track =
      insert_track(
        project: insert_project(user: owner, runtime: "codex"),
        conversation_id: "noisy"
      )

    # One short turn, then 1,000 events of turn-less output: five pages of it.
    log = sparse(1, 10) ++ unbound(11..1010, "out ")
    base = "/api/conversations/noisy"
    routes = Fixture.desc_routes(base <> "/events", log)
    assert length(routes) == 6

    client =
      FakeTransport.client([
        {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: []}}} | routes
      ])

    stub(Fountain, :client, fn -> client end)
    assert {:ok, page} = Tracks.events(owner, track.id)
    # Not the whole log before first paint: three pages, rendered as read.
    assert length(event_calls(client)) == 3
    assert [%{id: newest} = run] = page.turns
    assert newest == "pending:#{id(411)}" and length(run.events) == 600
    assert page.last_event_id == List.last(log)["id"]
    assert Transcript.History.more?(page.history) and page.history.held == []

    assert {:ok, page} = earlier(owner, track.id, page)
    assert length(event_calls(client)) == 6
    refute Transcript.History.more?(page.history)
    assert Enum.map(page.turns, & &1.id) == ["t1", "pending:#{id(11)}", newest]
    assert page.turns |> Enum.map(&length(&1.events)) |> Enum.sum() == length(log)
  end

  test "a turn split at Fountain's ceiling, turn-less runs cut by the limit and older conversations each render once, whole" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project, conversation_id: "new")
    thread = Repo.get!(Thread, track.id)
    Repo.update!(Ecto.Changeset.change(thread, previous_conversation_ids: ["old", "middle"]))

    # Setup output, one 6,000-event turn and three small ones after it.
    new =
      unbound(1..3, "setup ") ++
        sparse(1, 6000, prefix: "big", from: 3) ++ sparse(3, 10, prefix: "small", from: 6003)

    # 300 events of turn-less output, which `limit` alone pages, then a turn.
    middle = unbound(1..300, "boot ") ++ sparse(1, 10, prefix: "m", from: 300)
    old = sparse(1, 5, prefix: "o")
    logs = %{"new" => new, "middle" => middle, "old" => old}

    routes =
      Enum.flat_map(logs, fn {id, log} ->
        path = "/api/conversations/#{id}"

        [
          {%{method: "GET", path: path <> "/turns"}, {200, [], %{data: []}}}
          | Fixture.desc_routes(path <> "/events", log)
        ]
      end)

    client = FakeTransport.client(routes)
    stub(Fountain, :client, fn -> client end)

    assert [{_, {200, [], split}} | _] = Fixture.desc_routes("/", new)
    assert split["page"]["turn_split"] and length(split["data"]) == 5000

    assert {:ok, page} = Tracks.events(owner, track.id)
    # The split turn is held back for the page it continues on.
    assert Enum.map(page.turns, & &1.id) == ["small1", "small2", "small3"]
    assert length(event_calls(client)) == 1
    assert page.last_event_id == List.last(new)["id"]

    steps = [
      {["big1"], 2},
      {["pending:#{hd(new)["id"]}"], 3},
      {["m1"], 4},
      {["middle:pending:#{hd(middle)["id"]}"], 5},
      {["o1"], 6}
    ]

    page =
      Enum.reduce(steps, page, fn {added, calls}, page ->
        held = MapSet.new(page.turns, & &1.id)
        assert {:ok, page} = earlier(owner, track.id, page)
        assert Enum.reject(Enum.map(page.turns, & &1.id), &MapSet.member?(held, &1)) == added
        assert length(event_calls(client)) == calls
        page
      end)

    refute Transcript.History.more?(page.history)
    ids = Enum.map(page.turns, & &1.id)
    assert ids == Enum.uniq(ids)
    assert length(Enum.find(page.turns, &(&1.id == "big1")).events) == 6000

    expected =
      [{"middle", middle}, {"old", old}]
      |> Enum.reduce(full("new", new), fn {id, log}, page ->
        Transcript.prepend_history(page, full(id, log))
      end)

    assert comparable(page.turns) == comparable(expected.turns)
  end

  test "the live follow resumes from the first page's newest cursor" do
    Ravix.TracksBoot.ensure_running()
    owner = insert_user()
    track = insert_track(project: insert_project(user: owner), conversation_id: "follow")
    log = sparse(3, 10)
    base = "/api/conversations/follow"
    newest = List.last(log)["id"]

    client =
      FakeTransport.client([
        {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: []}}}
        | Fixture.desc_routes(base <> "/events", log)
      ])

    stub(Fountain, :client, fn -> client end)
    assert {:ok, page} = Tracks.events(owner, track.id)
    assert page.last_event_id == newest
    next = newest + 3

    stream =
      FakeTransport.client(
        [
          {%{method: "GET", path: base <> "/stream", headers: [{"last-event-id", "#{newest}"}]},
           {200, [{"content-type", "text/event-stream"}],
            [
              FakeTransport.frame(
                next,
                "output",
                Fixture.output(next, Fixture.text("live"), "t3")
              )
            ]}}
        ],
        verify: false
      )

    assert {:ok, follower} =
             Tracks.follow(owner, track.id,
               after: page.last_event_id,
               client: stream,
               stream_opts: [max_retries: 0, retry_delay: 1],
               retry_ms: 10,
               linger_ms: 100
             )

    track_id = track.id
    assert_receive {:transcript, ^track_id, %Transcript.Event{id: ^next}}, 1_000
    assert [%{headers: headers} | _] = FakeTransport.calls(stream)
    assert {"last-event-id", "#{newest}"} in headers
    # Stop the follower here rather than let it linger past the test's sandbox.
    DynamicSupervisor.terminate_child(Tracks.Follower.supervisor(), follower)
  end

  test "a Fountain without page objects falls back to the forward read, reusing its first page" do
    owner = insert_user()

    track =
      insert_track(
        project: insert_project(user: owner, runtime: "codex"),
        conversation_id: "long"
      )

    log = sparse(35, 200)
    base = "/api/conversations/long"
    [first_query | _] = for {query, _} <- Fixture.desc_pages(log), do: query

    # The desc page an older Fountain answered forward (200 events), then the
    # forward read's 1,000-event pages from its cursor.
    queries =
      [first_query] ++
        for index <- 0..6,
            do: %{
              "limit" => "1000",
              "blocks" => "true",
              "prompts" => "true",
              "after" => to_string(Enum.at(log, 199 + index * 1000)["id"])
            }

    routes =
      for query <- queries,
          do:
            {%{method: "GET", path: base <> "/events", query: query},
             {200, [], Fixture.events_body(log, query, legacy: true)}}

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
    assert page.oldest_event_id == Enum.at(log, 5000)["id"]
    assert page.last_event_id == List.last(log)["id"]
    assert Transcript.add_event(page, hd(log)) == page
    # The desc request an older Fountain answered forward is the first of eight.
    assert length(event_calls(client, base)) == 8
    assert_receive {:span, initial = span(name: "tracks.events")}
    assert attributes(initial)["ravix.event_pages"] == 8
    assert attributes(initial)["ravix.events_fetched"] == 7000
    assert attributes(initial)["ravix.events_order"] == "asc"
    calls = FakeTransport.calls(client)
    assert {:error, :not_found} = Tracks.earlier_events(insert_user(), track.id, page.history)
    assert {:ok, page} = earlier(owner, track.id, page)
    assert comparable(page.turns) == comparable(Enum.take(full.turns, -20))
    assert page.last_event_id == List.last(log)["id"]
    assert_receive {:span, span(name: "tracks.events.earlier")}
    assert {:ok, page} = earlier(owner, track.id, page)
    assert {:ok, page} = earlier(owner, track.id, page)
    refute Transcript.History.more?(page.history)
    assert comparable(page.turns) == comparable(full.turns)
    assert page.oldest_event_id == hd(log)["id"]
    assert {:ok, ^page} = earlier(owner, track.id, page)
    assert FakeTransport.calls(client) == calls
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

    logs = %{
      "new" => [Fixture.output(100, Fixture.text("new"), "new-turn")],
      "middle" => [Fixture.output(50, Fixture.text("middle"), "middle-turn")],
      "old" => [Fixture.output(1, Fixture.text("old"), "old-turn")]
    }

    stub(Fountain, :events_page, fn _, id, opts ->
      assert opts[:order] == :desc and opts[:whole_turns]
      Fixture.events_page(Map.fetch!(logs, id), opts)
    end)

    assert {:ok, page} = Tracks.events(owner, track.id)
    assert Enum.map(page.turns, & &1.id) == ["new-turn"]
    other = insert_track(project: project, conversation_id: "other")
    assert {:error, :not_found} = Tracks.earlier_events(owner, other.id, page.history)
    forged = %{page | history: %{page.history | conversations: ["someone-else"]}}
    assert {:error, :not_found} = Tracks.earlier_events(owner, track.id, forged.history)
    expect(Fountain, :events_page, fn _, "middle", _ -> {:error, :offline} end)
    assert {:error, :offline} = earlier(owner, track.id, page)
    assert {:ok, page} = earlier(owner, track.id, page)
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

  defp event_calls(client, path \\ nil) do
    Enum.filter(FakeTransport.calls(client), fn call ->
      if path, do: call.path == path <> "/events", else: String.ends_with?(call.path, "/events")
    end)
  end

  # What a full build of one conversation renders, with its source recorded.
  defp full(id, log) do
    page = Transcript.page(Transcript.History.label(log), "codex", %{})

    %{
      page
      | conversation_id: id,
        turns: Enum.map(page.turns, &%{&1 | conversation_id: id})
    }
  end

  # Settled turns of `size` events on sparse ids, as Fountain's are global:
  # each opened by its prompt, then output, then `completed`.
  defp sparse(count, size, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "t")
    from = Keyword.get(opts, :from, 0)

    Enum.flat_map(1..count, fn turn ->
      turn_id = "#{prefix}#{turn}"
      slot = from + (turn - 1) * size + 1

      opened =
        Fixture.stage(id(slot), "started")
        |> Map.put("turn_id", turn_id)
        |> Map.put("blocks", [%{"kind" => "prompt", "body" => "Prompt #{turn_id}"}])

      output =
        Enum.map((slot + 1)..(slot + size - 2)//1, fn slot ->
          Fixture.output(id(slot), Fixture.text("text "), turn_id)
        end)

      closed = Map.put(Fixture.stage(id(slot + size - 1), "completed"), "turn_id", turn_id)
      [opened | output] ++ [closed]
    end)
  end

  defp unbound(slots, body),
    do: Enum.map(slots, &Map.put(Fixture.output(id(&1), Fixture.text(body)), "turn_id", nil))

  defp id(slot), do: slot * 3 + 2

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

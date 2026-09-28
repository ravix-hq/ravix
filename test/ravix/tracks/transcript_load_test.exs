defmodule Ravix.Tracks.TranscriptLoadTest do
  use Ravix.DataCase, async: false
  use Ravix.TraceCase, async: false
  import Mimic
  alias Ravix.Fountain
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Trace
  alias Ravix.Tracks
  alias Ravix.Tracks.{AgentFailure, Settlement, Store, Thread, Transcript, TurnFailure}
  alias Ravix.TranscriptFixture, as: Fixture

  setup :verify_on_exit!

  test "snapshot rendering matches the pre-hotfix corpus" do
    path = Path.expand("../../fixtures/acp/transcript-golden.json", __DIR__)
    golden = path |> File.read!() |> Jason.decode!()

    actual =
      Map.new(Fixture.corpus(), fn {name, events} ->
        {name, events |> Transcript.page("codex") |> Fixture.public()}
      end)
      |> Jason.encode!()
      |> Jason.decode!()

    assert actual == golden
  end

  test "incremental catch-up reads only newer pages, preserves history, and traces each CPU step" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project, conversation_id: "catch-up")
    first = Fixture.output(1, Fixture.text("hello "))
    missed = Fixture.output(2, Fixture.text("missed "))
    newest = Fixture.output(3, Fixture.text("latest"))
    page = %{Transcript.page([first], "codex") | conversation_id: "catch-up"}

    old_events = [
      Fixture.output(1, Fixture.text("old"), "archived"),
      Map.put(Fixture.stage(2, "completed"), "turn_id", "archived")
    ]

    [historical] =
      Transcript.page(old_events, "codex", %{
        "archived" => %{code: "agent_provider_unreachable", reason: "Retained failure"}
      }).turns

    historical = %{historical | image_count: 2, conversation_id: "archived-conversation"}
    page = %{page | turns: [historical | page.turns]}
    base = "/api/conversations/catch-up"

    client =
      FakeTransport.client([
        {%{
           method: "GET",
           path: base <> "/events",
           query: %{after: "1", limit: "1000", blocks: "true", prompts: "true"}
         }, {200, [], %{data: [missed], meta: %{has_more: true, next_cursor: 2}}}},
        {%{
           method: "GET",
           path: base <> "/events",
           query: %{after: "2", limit: "1000", blocks: "true", prompts: "true"}
         }, {200, [], %{data: [newest], meta: %{has_more: false}}}},
        {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: []}}}
      ])

    stub(Fountain, :client, fn -> client end)
    assert {:error, :not_found} = Tracks.events(insert_user(), track.id, page: page)
    assert FakeTransport.calls(client) == []
    assert {:ok, result} = Tracks.events(owner, track.id, page: page)
    assert result.last_event_id == 3
    assert [retained, %{blocks: [%{body: "hello missed latest"}]}] = result.turns
    assert retained == historical
    assert_receive {:span, build = span(name: "transcript.build", parent_span_id: parent)}
    assert attributes(build)["ravix.event_count"] == 2
    assert_receive {:span, span(name: "transcript.images", parent_span_id: ^parent)}
    assert_receive {:span, span(name: "transcript.failures", parent_span_id: ^parent)}
    assert_receive {:span, span(name: "tracks.events", span_id: ^parent)}
  end

  test "successful settlement is classified once; failed acquisition can retry" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project, conversation_id: "settlement")
    client = Fountain.Client.new("https://fountain.test", "key")
    event = Fixture.stage(2, "completed") |> Transcript.Event.from()
    expect(Fountain, :events, fn _, "settlement", [] -> {:error, :offline} end)
    assert {:error, :offline} = Settlement.record(client, track.id, "settlement", event)
    assert Repo.all(TurnFailure) == []
    expect(Fountain, :events, fn _, "settlement", [] -> {:ok, [Fixture.stage(1, "started")]} end)
    assert {:ok, _} = Settlement.record(client, track.id, "settlement", event)
    assert {:ok, _} = Settlement.record(client, track.id, "settlement", event)
    assert [%{stage: "classification", state: "completed"}] = Repo.all(TurnFailure)
    assert_receive {:span, detection = span(name: "transcript.failure_detection")}
    assert attributes(detection)["ravix.event_count"] == 2
    refute_receive {:span, span(name: "transcript.failure_detection")}
    assert :ok = Settlement.record(client, track.id, "replaced-conversation", event)
  end

  test "the follower persists an outage before broadcasting settlement, including a replay" do
    Ravix.TracksBoot.ensure_running()
    owner = insert_user()

    track =
      insert_track(
        project: insert_project(user: owner, runtime: "codex"),
        conversation_id: "stream-outage"
      )

    log = Ravix.AgentOutageFixture.events()
    done = List.last(log)
    frame = FakeTransport.frame(done["id"], "stage", done)
    base = "/api/conversations/stream-outage"

    client =
      FakeTransport.client(
        [
          {%{method: "GET", path: base <> "/stream"}, {200, [], [frame]}},
          {%{method: "GET", path: base <> "/events"}, {200, [], %{data: log}}},
          {%{method: "GET", path: base <> "/stream"}, {200, [], [frame]}}
        ],
        verify: false
      )

    assert {:ok, pid} =
             Tracks.Follower.subscribe(track.id,
               conversation_id: "stream-outage",
               client: client,
               retry_ms: 10
             )

    id = track.id
    assert_receive {:transcript, ^id, %{id: 8}}, 2_000
    assert Enum.any?(Repo.all(TurnFailure), &(&1.code == "agent_provider_unreachable"))
    assert_receive {:transcript, ^id, %{id: 8}}, 2_000
    DynamicSupervisor.terminate_child(Tracks.Follower.supervisor(), pid)
    assert Enum.count(FakeTransport.calls(client), &(&1.path == base <> "/events")) == 1
    assert length(Repo.all(TurnFailure)) == 2
  end

  test "sandbox suspension is attached to the open turn and its correction survives reads" do
    owner = insert_user()

    track =
      insert_track(
        project: insert_project(user: owner, runtime: "codex"),
        conversation_id: "sleep"
      )

    client = Fountain.Client.new("https://fountain.test", "key")

    suspension = %{
      "id" => 3,
      "kind" => "stage",
      "stage" => "sandbox",
      "state" => "done",
      "data" => Jason.encode!(%{event: "suspended"})
    }

    log = [Fixture.stage(1, "started"), Fixture.output(2, Fixture.text("working")), suspension]
    expect(Fountain, :events, fn _, "sleep", [] -> {:ok, log} end)

    assert {:ok, _} =
             Settlement.record(client, track.id, "sleep", Transcript.Event.from(suspension))

    assert Enum.any?(
             Repo.all(TurnFailure),
             &(&1.code == "machine_suspended" and &1.turn_id == "t")
           )

    expect(Fountain, :events, fn _, "sleep", [] ->
      {:ok, [Fixture.stage(1, "completed"), suspension]}
    end)

    assert :ok = Settlement.record(client, track.id, "sleep", Transcript.Event.from(suspension))
  end

  for mode <- [:current, :archived, :retry] do
    @tag classification_source: mode, capture_log: true
    test "unwatched #{mode} turns classify in the background once and publish their correction",
         %{classification_source: mode} do
      owner = insert_user()
      project = insert_project(user: owner, runtime: "codex")
      target_id = "unwatched-#{mode}"
      active_id = if mode == :archived, do: "active-#{mode}", else: target_id
      track = insert_track(project: project, conversation_id: active_id)
      thread = Repo.get!(Thread, track.id)

      if mode == :archived,
        do: Repo.update!(Ecto.Changeset.change(thread, previous_conversation_ids: [target_id]))

      client = Fountain.Client.new("https://fountain.test", "key")
      stub(Fountain, :client, fn -> client end)
      log = Ravix.AgentOutageFixture.events()

      stub(Fountain, :events, fn _, id, _opts -> {:ok, if(id == target_id, do: log, else: [])} end)

      stub(Fountain, :events_page, fn _, id, opts ->
        Fixture.events_page(if(id == target_id, do: log, else: []), opts)
      end)

      stub(Fountain, :turns, fn _, _ -> {:ok, []} end)
      parent = self()

      stub(Trace, :span, fn name, attributes, fun ->
        if name == "transcript.background", do: await_background(parent)
        Mimic.call_original(Trace, :span, [name, attributes, fun])
      end)

      if mode == :retry do
        expect(AgentFailure, :detect, fn _, _, _ -> raise "classification interrupted" end)
      end

      expect(AgentFailure, :detect, fn events, runtime, blocks ->
        Mimic.call_original(AgentFailure, :detect, [events, runtime, blocks])
      end)

      Ravix.Hub.subscribe(project.id)
      refute Tracks.Follower.whereis(track.id)
      # This returns while the classifier is deliberately blocked. It cannot
      # be a synchronous scan or wait hidden inside tracks.events.
      assert {:ok, page} = Tracks.events(owner, track.id)

      page =
        if mode == :archived do
          assert page.turns == []
          assert {:ok, older} = Tracks.earlier_events(owner, track.id, page.history)
          Transcript.prepend_history(page, older)
        else
          page
        end

      assert_receive {:classifying, worker}
      worker = if mode == :retry, do: retry_background(worker, owner, track), else: worker
      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      assert worker != self()
      assert worker in Task.Supervisor.children(Ravix.TaskSupervisor)
      assert Ravix.Cluster.whereis(:settlement, target_id <> "/mine") == worker
      assert [%{blocks: []}] = page.turns
      for _ <- 1..3, do: assert({:ok, _} = Tracks.events(owner, track.id))
      assert Ravix.Cluster.whereis(:settlement, target_id <> "/mine") == worker
      monitor = Process.monitor(worker)
      send(worker, :finish)
      track_id = track.id
      assert_receive {:hub, %{name: :turn, track_id: ^track_id, thread_id: ^track_id}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
      refute Ravix.Cluster.whereis(:settlement, target_id <> "/mine")
      assert length(Repo.all(TurnFailure)) == 2

      # The hub repair fetches only the active conversation's delta, yet picks
      # up a newly recorded correction from an archived conversation too.
      expect(Fountain, :events, fn _, ^active_id, opts ->
        assert opts[:after] == page.last_event_id
        {:ok, []}
      end)

      assert {:ok, repaired} = Tracks.events(owner, track.id, page: page)
      assert [%{blocks: [%Transcript.Block.Failure{}], visible?: true}] = repaired.turns
      refute_receive {:classifying, _}
    end
  end

  test "classification pages back only to the first classified settled turn, and not at all once it is there" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project, conversation_id: "scan")
    base = "/api/conversations/scan"
    # The read's 200-event page is t7, whole; the scan's 1,000-event pages
    # are t5-t6, t3-t4, t1-t2.
    log = settled_turns(7, 600)
    assert [p1, p2, p3, _p4] = Fixture.desc_routes(base <> "/events", log, then: 1000)
    assert match?({%{query: %{"limit" => "1000"}}, _}, p2)
    {:ok, _} = Store.classify_turn_once("scan", "t3", fn -> {:ok, nil} end)
    turns = {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: []}}}
    client = FakeTransport.client([p1, turns, p2, p3])
    stub(Fountain, :client, fn -> client end)
    parent = self()

    stub(Trace, :span, fn name, attributes, fun ->
      if name == "transcript.classification_scan", do: send(parent, {:scanning, self()})
      Mimic.call_original(Trace, :span, [name, attributes, fun])
    end)

    assert {:ok, page} = Tracks.events(owner, track.id)
    assert Enum.map(page.turns, & &1.id) == ["t7"]
    await_scan()
    # The read took one page and the scan two more, stopping at t3: t1 and t2
    # were never read.
    assert length(event_paths(client)) == 3
    assert classified("scan") == ~w(t3 t4 t5 t6 t7)

    FakeTransport.expect(client, elem(p1, 0), elem(p1, 1))
    FakeTransport.expect(client, elem(turns, 0), elem(turns, 1))
    assert {:ok, _} = Tracks.events(owner, track.id)
    await_scan()
    # Everything on the newest page is classified: no request beyond the read.
    assert length(event_paths(client)) == 4
    assert classified("scan") == ~w(t3 t4 t5 t6 t7)
  end

  test "a running turn over the limit makes no extra request when the turns behind it are classified" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project, conversation_id: "running")
    base = "/api/conversations/running"
    # t3 is still running, 600 events in: the read's whole page is only t3.
    running = settled_turns(3, 600) |> Enum.drop(-1)
    [read | _older] = Fixture.desc_routes(base <> "/events", running, then: 1000)
    assert Enum.all?(elem(elem(read, 1), 2)["data"], &(&1["turn_id"] == "t3"))

    for turn <- ~w(t1 t2),
        do: {:ok, _} = Store.classify_turn_once("running", turn, fn -> {:ok, nil} end)

    turns = {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: []}}}
    client = FakeTransport.client([read, turns])
    stub(Fountain, :client, fn -> client end)
    scanning(self())

    assert {:ok, %{turns: [%{id: "t3", settled?: false}]}} = Tracks.events(owner, track.id)
    await_scan()
    assert length(event_paths(client)) == 1
  end

  test "a first open mid-turn still walks back, and one walk per conversation runs at a time" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project, conversation_id: "walk")
    base = "/api/conversations/walk"
    running = settled_turns(3, 600) |> Enum.drop(-1)
    [read, older] = Fixture.desc_routes(base <> "/events", running, then: 1000)
    turns = {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: []}}}
    client = FakeTransport.client([read, turns])
    stub(Fountain, :client, fn -> client end)
    scanning(self())

    # Another walk of this conversation holds the lock: this scan does not walk.
    lock = {Ravix.Cluster.name(:settlement_scan, "walk"), self()}
    assert :global.set_lock(lock, [node()], 0)
    assert {:ok, _} = Tracks.events(owner, track.id)
    await_scan()
    assert length(event_paths(client)) == 1
    :global.del_lock(lock, [node()])

    # Nothing classified yet, so the running turn does not stop the walk.
    FakeTransport.expect(client, elem(read, 0), elem(read, 1))
    FakeTransport.expect(client, elem(turns, 0), elem(turns, 1))
    FakeTransport.expect(client, elem(older, 0), elem(older, 1))
    assert {:ok, _} = Tracks.events(owner, track.id)
    await_scan()
    assert length(event_paths(client)) == 3
    assert classified("walk") == ~w(t1 t2)
  end

  test "a scan reads back at most twenty pages" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project, conversation_id: "budget")
    base = "/api/conversations/budget"
    # One 1,000-event turn per scan page: t23 is read, t22 back to t3 scanned.
    routes = Fixture.desc_routes(base <> "/events", settled_turns(23, 1000), then: 1000)
    assert length(routes) == 23
    [read | scanned] = Enum.take(routes, 21)
    turns = {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: []}}}
    client = FakeTransport.client([read, turns | scanned])
    stub(Fountain, :client, fn -> client end)
    scanning(self())

    assert {:ok, _} = Tracks.events(owner, track.id)
    await_scan()
    assert length(event_paths(client)) == 21
    assert classified("budget") == Enum.sort(for n <- 3..23, do: "t#{n}")
  end

  test "unscrolled settled turns on older pages classify in the background, bounded and off the read" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project, conversation_id: "unscrolled")
    base = "/api/conversations/unscrolled"

    log =
      Ravix.AgentOutageFixture.events() ++
        (settled_turns(3, 600) |> Enum.map(&Map.update!(&1, "id", fn id -> id + 100 end)))

    # The read's page is t3; the scan's are t1-t2, then the outage turn.
    assert [first, second, third] = Fixture.desc_routes(base <> "/events", log, then: 1000)
    refute Enum.any?(elem(elem(first, 1), 2)["data"], &(&1["turn_id"] == "mine"))
    turns = {%{method: "GET", path: base <> "/turns"}, {200, [], %{data: []}}}
    client = FakeTransport.client([first, turns, second, third])
    stub(Fountain, :client, fn -> client end)
    parent = self()

    stub(Trace, :span, fn name, attributes, fun ->
      if name == "transcript.background", do: await_background(parent)
      if name == "transcript.classification_scan", do: send(parent, {:scanning, self()})
      Mimic.call_original(Trace, :span, [name, attributes, fun])
    end)

    assert {:ok, page} = Tracks.events(owner, track.id)
    refute Enum.any?(page.turns, &(&1.id == "mine"))
    assert_receive {:scanning, worker}, 1_000
    monitor = Process.monitor(worker)
    # Each classification waits on the test; the read already returned.
    # Three pages, four settled turns: t3, t1 and t2, then "mine".
    assert release_classifications(worker, monitor, 0) == 4
    assert length(event_paths(client)) == 3

    assert Enum.any?(
             Repo.all(TurnFailure),
             &(&1.turn_id == "mine" and &1.code == "agent_provider_unreachable")
           )
  end

  test "historical backfill is explicit, idempotent and keeps live turns unclassified" do
    owner = insert_user()

    track =
      insert_track(
        project: insert_project(user: owner, runtime: "codex"),
        conversation_id: "history"
      )

    client = Fountain.Client.new("https://fountain.test", "key")

    log =
      Ravix.AgentOutageFixture.events() ++
        [Fixture.output(20, Fixture.text("still going"), "live")]

    expect(Fountain, :events, 2, fn _, "history", [] -> {:ok, log} end)
    assert :ok = Settlement.backfill(track.id, client)
    rows = Repo.all(TurnFailure)
    assert length(rows) == 2
    assert :ok = Settlement.backfill(track.id, client)
    assert Repo.all(TurnFailure) == rows
    assert {:error, :not_found} = Settlement.backfill(Ecto.UUID.generate(), client)
  end

  defp release_classifications(worker, monitor, count) do
    receive do
      {:classifying, ^worker} ->
        send(worker, :finish)
        release_classifications(worker, monitor, count + 1)

      {:DOWN, ^monitor, :process, ^worker, :normal} ->
        count
    after
      2_000 -> flunk("the scan neither classified nor finished")
    end
  end

  defp scanning(parent) do
    stub(Trace, :span, fn name, attributes, fun ->
      if name == "transcript.classification_scan", do: send(parent, {:scanning, self()})
      Mimic.call_original(Trace, :span, [name, attributes, fun])
    end)
  end

  defp await_scan do
    assert_receive {:scanning, worker}, 1_000
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 5_000
    assert reason in [:normal, :noproc]
  end

  defp event_paths(client),
    do:
      for(
        %{path: path} <- FakeTransport.calls(client),
        String.ends_with?(path, "/events"),
        do: path
      )

  defp classified(conversation_id),
    do:
      Store.turn_classifications([conversation_id]).classified
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort()

  # Settled turns on sparse ids: opened, `size - 2` outputs, completed.
  defp settled_turns(count, size) do
    Enum.flat_map(1..count, fn turn ->
      first = (turn - 1) * size + 1
      id = &(&1 * 3 + 2)
      turn_id = "t#{turn}"

      [Map.put(Fixture.stage(id.(first), "started"), "turn_id", turn_id)] ++
        Enum.map(
          (first + 1)..(first + size - 2),
          &Fixture.output(id.(&1), Fixture.text("x "), turn_id)
        ) ++
        [Map.put(Fixture.stage(id.(first + size - 1), "completed"), "turn_id", turn_id)]
    end)
  end

  defp retry_background(worker, owner, track) do
    monitor = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 2_000
    refute reason == :normal
    assert Repo.all(TurnFailure) == []
    refute Ravix.Cluster.whereis(:settlement, track.conversation_id <> "/mine")
    assert {:ok, _} = Tracks.events(owner, track.id)
    assert_receive {:classifying, replacement}
    refute replacement == worker
    replacement
  end

  defp await_background(parent) do
    send(parent, {:classifying, self()})

    receive do
      :finish -> :ok
    end
  end

  test "a snapshot that ends asleep marks a dedicated track asleep, and one with a later turn wakes it" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")

    track =
      insert_track(
        project: project,
        conversation_id: "sleepy",
        sandbox_layout: :dedicated,
        sandbox_state: :ready
      )

    suspended = %{
      "id" => 1,
      "kind" => "stage",
      "stage" => "sandbox",
      "state" => "done",
      "data" => ~s({"event":"suspended","reason":"idle"})
    }

    woke = Map.merge(Fixture.stage(2, "started"), %{"turn_id" => "t2"})
    client = Fountain.Client.new("https://fountain.test", "key")
    stub(Fountain, :client, fn -> client end)
    stub(Fountain, :turns, fn _, _ -> {:ok, []} end)

    for {log, asleep?} <- [{[suspended], true}, {[suspended, woke], false}] do
      stub(Fountain, :events_page, fn _, "sleepy", opts -> Fixture.events_page(log, opts) end)
      running = Task.Supervisor.children(Ravix.TaskSupervisor)
      assert {:ok, _page} = Tracks.events(owner, track.id)
      settle_background(running)
      assert is_nil(Repo.get!(Tracks.Track, track.id).sandbox_suspended_at) == not asleep?
    end
  end

  # Classification of the snapshot's settled turns runs in the background;
  # wait for the tasks this read started, not anybody else's.
  defp settle_background(running) do
    Ravix.TaskSupervisor
    |> Task.Supervisor.children()
    |> Kernel.--(running)
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, :process, _, _}, 5_000 end)
  end
end

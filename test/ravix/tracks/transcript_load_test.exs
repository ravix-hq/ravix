defmodule Ravix.Tracks.TranscriptLoadTest do
  use Ravix.DataCase, async: false
  use Ravix.TraceCase, async: false
  import Mimic
  alias Ravix.Fountain
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Tracks
  alias Ravix.Tracks.{Settlement, Transcript, TurnFailure}
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
    assert [%{blocks: [%{body: "hello missed latest"}]}] = result.turns
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
end

defmodule Ravix.Tracks.FollowerTest do
  use Ravix.DataCase, async: true

  import ExUnit.CaptureLog

  alias Ravix.Fountain.FakeTransport
  alias Ravix.Tracks.Follower
  alias Ravix.Tracks.Transcript.Event

  @stream_opts [max_retries: 0, retry_delay: 1]

  setup_all do
    Ravix.TracksBoot.ensure_running()
    :ok
  end

  setup do
    {:ok,
     track_id: Ecto.UUID.generate(), conversation_id: "c-#{System.unique_integer([:positive])}"}
  end

  defp frames(ids) do
    Enum.map(
      ids,
      &FakeTransport.frame(&1, "output", %{
        id: &1,
        kind: "output",
        stream: "acp",
        data: "line #{&1}"
      })
    )
  end

  # The stream, then the reconnect from the last id seen. Anything after that
  # is unmatched, which is what a Fountain that stays quiet looks like to the
  # fake; the follower keeps trying, and that is not this test's business.
  defp client(conversation_id) do
    path = "/api/conversations/#{conversation_id}/stream"

    FakeTransport.client(
      [
        {%{method: "GET", path: path},
         {200, [{"content-type", "text/event-stream"}], frames([1, 2])}},
        {%{method: "GET", path: path, headers: [{"last-event-id", "2"}]}, {200, [], frames([3])}}
      ],
      verify: false
    )
  end

  defp subscribe(ctx, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new_lazy(:client, fn -> client(ctx.conversation_id) end)
      |> Keyword.merge(
        conversation_id: ctx.conversation_id,
        stream_opts: @stream_opts,
        retry_ms: 10,
        linger_ms: 100
      )

    Follower.subscribe(ctx.track_id, opts)
  end

  test "events are broadcast to the subscriber, and the stream is resumed from the last id",
       ctx do
    assert {:ok, _follower} = subscribe(ctx)
    track_id = ctx.track_id
    assert_receive {:transcript, ^track_id, %Event{id: 1, data: "line 1"}}, 1_000
    assert_receive {:transcript, ^track_id, %Event{id: 2}}, 1_000
    # The second connection asked for what came after 2.
    assert_receive {:transcript, ^track_id, %Event{id: 3}}, 1_000
  end

  describe "a turn's prompt" do
    defp opening(id), do: %{id: id, turn_id: "t1", kind: "stage", stage: "turn", state: "started"}

    # A stream that opens a turn at event 5 and says something at 6, and a
    # feed that answers the one-event read of 5 with `feed`.
    defp opening_client(conversation_id, feed) do
      stream = "/api/conversations/#{conversation_id}/stream"
      events = "/api/conversations/#{conversation_id}/events"

      FakeTransport.client(
        [
          {%{method: "GET", path: stream},
           {200, [{"content-type", "text/event-stream"}],
            [
              FakeTransport.frame(5, "stage", opening(5)),
              FakeTransport.frame(6, "output", %{
                id: 6,
                turn_id: "t1",
                kind: "output",
                stream: "acp",
                data: "x"
              })
            ]}},
          {%{
             method: "GET",
             path: events,
             query: %{limit: "1", after: "4", blocks: "true", prompts: "true"}
           }, feed}
        ],
        verify: false
      )
    end

    test "is read from the feed as the turn opens, and broadcast on its opening event", ctx do
      feed =
        {200, [],
         %{
           data: [Map.put(opening(5), :blocks, [%{kind: "prompt", body: "do the thing"}])],
           meta: %{has_more: false}
         }}

      client = opening_client(ctx.conversation_id, feed)
      assert {:ok, _follower} = subscribe(ctx, client: client)
      track_id = ctx.track_id

      assert_receive {:transcript, ^track_id, %Event{id: 5, prompt: "do the thing"}}, 1_000
      assert_receive {:transcript, ^track_id, %Event{id: 6, prompt: nil}}, 1_000

      # Once, for the opening event, and not for the output after it.
      assert [_one] =
               Enum.filter(FakeTransport.calls(client), &String.ends_with?(&1.path, "/events"))
    end

    test "is left off when the feed cannot answer, and the event still goes out", ctx do
      client = opening_client(ctx.conversation_id, {503, [], %{error: "offline"}})
      assert {:ok, _follower} = subscribe(ctx, client: client)
      track_id = ctx.track_id

      capture_log(fn ->
        assert_receive {:transcript, ^track_id, %Event{id: 5, prompt: nil}}, 1_000
        assert_receive {:transcript, ^track_id, %Event{id: 6}}, 1_000
      end)
    end
  end

  test "one follower per track, shared by every subscriber", ctx do
    assert {:ok, _follower} = subscribe(ctx)
    pid = Follower.whereis(ctx.track_id)
    assert is_pid(pid)

    parent = self()
    # A client is scripted from the test process; the spawned page gets it.
    client = client(ctx.conversation_id)

    other =
      spawn(fn ->
        {:ok, _} = subscribe(ctx, client: client)
        send(parent, {:other, Follower.whereis(ctx.track_id)})
        Process.sleep(:infinity)
      end)

    assert_receive {:other, ^pid}
    Process.exit(other, :kill)
  end

  test "the follower stops a little after its last subscriber leaves, and not before", ctx do
    assert {:ok, _follower} = subscribe(ctx)
    pid = Follower.whereis(ctx.track_id)
    ref = Process.monitor(pid)

    :ok = Follower.unsubscribe(ctx.track_id)
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 50
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert is_nil(Follower.whereis(ctx.track_id))
  end

  test "a subscriber that dies counts as having left", ctx do
    parent = self()
    client = client(ctx.conversation_id)

    watcher =
      spawn(fn ->
        {:ok, _} = subscribe(ctx, client: client)
        send(parent, :subscribed)
        Process.sleep(:infinity)
      end)

    assert_receive :subscribed
    pid = Follower.whereis(ctx.track_id)
    ref = Process.monitor(pid)
    Process.exit(watcher, :kill)

    # Deliberately not `assert_receive` with `:normal` in the pattern. An
    # unmatched pattern leaves the message in the mailbox and times out
    # saying nothing -- so a follower that exited for the wrong reason and
    # one that never exited looked identical from here. Take any exit, then
    # say which it was.
    #
    # The deadline is wall clock around a `linger_ms: 100` timer, and what
    # is under test is that the follower stops *at all* once nobody is
    # watching, not that it does so inside any particular millisecond. At
    # 1s this still failed intermittently on a loaded suite -- twenty cases
    # in flight, a 100 ms `send_after` and a monitor message all waiting on
    # the same schedulers -- which is a slow machine reported as a broken
    # follower. Five seconds is still two orders of magnitude under the
    # three-second production linger it would take to mean anything.
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        assert reason == :normal
    after
      5_000 ->
        flunk("""
        The follower did not stop within 5s of its last subscriber dying.
        alive: #{Process.alive?(pid)}
        state: #{if Process.alive?(pid), do: inspect(:sys.get_state(pid), limit: 20), else: "gone"}
        """)
    end
  end

  test "coming back within the grace period keeps the follower", ctx do
    assert {:ok, _follower} = subscribe(ctx)
    pid = Follower.whereis(ctx.track_id)
    :ok = Follower.unsubscribe(ctx.track_id)
    assert {:ok, _follower} = subscribe(ctx)
    Process.sleep(150)
    assert Process.alive?(pid)
    assert Follower.whereis(ctx.track_id) == pid
  end

  test "a track's conversation is read from its row, and a track without one cannot be followed",
       ctx do
    track = insert_track(conversation_id: ctx.conversation_id)

    assert {:ok, _follower} =
             Follower.subscribe(track.id,
               client: client(ctx.conversation_id),
               stream_opts: @stream_opts,
               linger_ms: 50
             )

    id = track.id
    assert_receive {:transcript, ^id, %Event{id: 1}}, 1_000

    unopened = insert_track(conversation_id: nil)
    assert {:error, :not_open} = Follower.subscribe(unopened.id)
  end
end

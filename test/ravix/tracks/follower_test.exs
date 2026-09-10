defmodule Ravix.Tracks.FollowerTest do
  use Ravix.DataCase, async: true

  alias Ravix.Fountain.FakeTransport
  alias Ravix.Tracks.Follower

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
    assert_receive {:transcript, ^track_id, %{"id" => 1, "data" => "line 1"}}, 1_000
    assert_receive {:transcript, ^track_id, %{"id" => 2}}, 1_000
    # The second connection asked for what came after 2.
    assert_receive {:transcript, ^track_id, %{"id" => 3}}, 1_000
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

    # Deliberately not `assert_receive` with `:normal` in the pattern. This
    # test fails intermittently under a loaded suite, and an unmatched pattern
    # leaves the message in the mailbox and times out saying nothing -- so a
    # follower that exited for the wrong reason and one that never exited
    # looked identical from here. Take any exit, then say which it was.
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        assert reason == :normal
    after
      1_000 ->
        flunk("""
        The follower did not stop within 1s of its last subscriber dying.
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
    assert_receive {:transcript, ^id, %{"id" => 1}}, 1_000

    unopened = insert_track(conversation_id: nil)
    assert {:error, :not_open} = Follower.subscribe(unopened.id)
  end
end

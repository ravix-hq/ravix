defmodule Ravix.Cluster.DistributionTest do
  @moduledoc """
  The parts that only a second BEAM can prove.

  Everything else about clustering can be tested on one node, because the
  contended `:global` name is the same one. These cannot: a name is only
  interesting when the process behind it is somewhere else, `busy?/1` only
  crosses nodes when the owner is another instance, PubSub fan-out is only
  fan-*out* across nodes, and a takeover only happens when a node leaves.

  A peer runs the whole application, as an instance does, so the names it
  contends for are the real ones. Each test gets its own and only one exists at
  a time: see the comment on `setup`.
  """
  use ExUnit.Case, async: false
  alias Ravix.Hub.Event

  @moduletag :distributed
  @moduletag :capture_log
  @moduletag timeout: 120_000

  alias Ravix.Cluster
  alias Ravix.Cluster.Singleton
  alias Ravix.Fountain.Client
  alias Ravix.Previews
  alias Ravix.Tracks.Follower

  @cookie :ravix_distribution_test

  # One peer per test, and never two at once. Nodes joining and leaving while
  # another is mid-teardown is what `:global`'s overlapping-partition protection
  # exists to catch, and it catches it by disconnecting nodes -- which looks
  # exactly like the failures these tests are meant to detect.
  setup do
    distribute!()
    {peer, node} = start_peer!()
    on_exit(fn -> stop_peer(peer, node) end)

    %{peer: peer, node: node}
  end

  describe "a per-track process is one process for the cluster" do
    test "a follower started on one instance is the follower on the other", %{node: node} do
      track_id = Ecto.UUID.generate()
      opts = follow_opts()

      assert {:ok, follower} = Follower.subscribe(track_id, opts)
      assert node(follower) == node()

      # The other instance finds it rather than starting its own, which is the
      # whole difference from the local `Registry` this replaced: a second
      # follower would put every event on the topic twice.
      assert :erpc.call(node, Follower, :whereis, [track_id]) == follower
      assert {:ok, ^follower} = :erpc.call(node, Follower, :subscribe, [track_id, opts])
    end

    test "a preview server is refused a second start on the other instance", %{node: node} do
      track_id = Ecto.UUID.generate()

      server = Previews.Server.ensure(track_id)
      assert node(server) == node()

      # `ensure/1` on the other instance is the lock holding: it returns the
      # server that already exists rather than a second one on its own node.
      assert :erpc.call(node, Previews.Server, :ensure, [track_id]) == server
    end
  end

  test "project mutation locks exclude another instance and release on node loss", ctx do
    id = Ecto.UUID.generate()

    for kind <- [:shared_machine, :secret_change] do
      holder = Node.spawn(ctx.node, Ravix.ClusterPeer, :hold_project_mutation, [self(), id, kind])
      assert_receive {:mutation_locked, ^holder}, 5_000

      assert {:error, {:conflict, "project_change_in_progress", _}} =
               Cluster.project_mutation(id, kind, fn -> flunk("overlapping mutation") end)

      monitor = Process.monitor(holder)
      send(holder, :release)
      assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 5_000
      assert :allowed = Cluster.project_mutation(id, kind, fn -> :allowed end)
    end

    holder =
      Node.spawn(ctx.node, Ravix.ClusterPeer, :hold_project_mutation, [
        self(),
        id,
        :shared_machine
      ])

    assert_receive {:mutation_locked, ^holder}, 5_000
    stop_peer(ctx.peer, ctx.node)
    assert :allowed = Cluster.project_mutation(id, :shared_machine, fn -> :allowed end)

    assert_raise RuntimeError, "failed allocation", fn ->
      Cluster.project_mutation(id, :shared_machine, fn -> raise "failed allocation" end)
    end

    assert :allowed = Cluster.project_mutation(id, :shared_machine, fn -> :allowed end)
  end

  describe "busy?/1 across instances" do
    test "reads the answer from the instance that owns the server", %{node: node} do
      track_id = Ecto.UUID.generate()
      server = Previews.Server.ensure(track_id)
      assert node(server) == node()

      # An idle server, read from the other instance: the answer travels, and
      # the reconciler over there is free to queue an `:ensure`.
      refute :erpc.call(node, Previews.Server, :busy?, [track_id])

      hold_busy(server)

      # And when it is working, the other instance is told to leave it alone.
      assert :erpc.call(node, Previews.Server, :busy?, [track_id])
    end

    test "a server whose instance left the cluster is nobody's server", ctx do
      track_id = Ecto.UUID.generate()

      server = :erpc.call(ctx.node, Previews.Server, :ensure, [track_id])
      assert node(server) == ctx.node

      stop_peer(ctx.peer, ctx.node)

      # `:global` releases the names of a node that leaves, so this is not an
      # unreachable owner -- it is no owner, and the next instance to want the
      # track starts one of its own. The reconciler is what puts the preview
      # back to what the database says it should be.
      assert eventually(fn -> Cluster.whereis(:preview, track_id) == nil end)
      refute Previews.Server.busy?(track_id)
      assert node(Previews.Server.ensure(track_id)) == node()
    end
  end

  describe "the transcript topic" do
    test "reaches a reader on another instance exactly once", %{node: node} do
      track_id = Ecto.UUID.generate()
      topic = Follower.topic(track_id)
      parent = self()

      # A named function in a compiled support module, not a closure: the peer
      # resolves code through the shared path, and a test module is never on it.
      Node.spawn(node, Ravix.ClusterPeer, :reader, [parent, [topic, "ping"]])

      assert_receive {:ready, _reader}, 30_000

      # The subscription is local to that node and reaches this one through
      # `:pg`, which syncs after the nodes connect. Ping until it is through, so
      # that the count below is a count and not a race.
      await_fanout()

      Phoenix.PubSub.broadcast(Ravix.PubSub, topic, {:transcript, track_id, %{"id" => 1}})

      assert_receive {:forwarded, {:transcript, ^track_id, %{"id" => 1}}}, 5_000
      refute_receive {:forwarded, {:transcript, ^track_id, _}}, 300
    end
  end

  describe "presence" do
    test "one change is one `here` frame per reader, not one per instance", ctx do
      track_id = Ecto.UUID.generate()
      project_id = Ecto.UUID.generate()
      parent = self()

      Ravix.Hub.subscribe(project_id)
      Node.spawn(ctx.node, Ravix.ClusterPeer, :reader, [parent, ["ping"]])
      assert_receive {:ready, _reader}, 30_000
      await_fanout()

      # Somebody appears on the *other* instance. Every node runs
      # `handle_metas/4` on the same diff, so a cluster-wide publish from in
      # there would reach this reader once per instance -- three frames for one
      # change, measured, before #19.
      user = %Ravix.Accounts.User{id: "u1", login: "ana", name: "Ana", avatar_url: nil}
      Node.spawn(ctx.node, Ravix.ClusterPeer, :beat_and_hold, [track_id, project_id, user])

      assert_receive {:hub, %Event{name: :here, track_id: ^track_id, present: present}},
                     30_000

      assert [%{login: "ana"}] = present

      # And exactly one. This is the assertion the issue was about.
      refute_receive {:hub, %Event{name: :here, track_id: ^track_id}}, 1_000
    end
  end

  describe "a cluster singleton" do
    test "moves to the surviving instance when the holder's node goes away", ctx do
      key = "takeover-#{System.unique_integer([:positive])}"
      parent = self()

      # The peer takes the name first, so this node is the one watching.
      Node.spawn(ctx.node, Ravix.ClusterPeer, :hold_singleton, [parent, key])

      assert_receive {:worker_started, :peer}, 30_000

      here =
        start_supervised!({Singleton, key: key, child: Ravix.ClusterPeer.worker(parent, :here)})

      refute Singleton.holding?(here)

      stop_peer(ctx.peer, ctx.node)

      # `:global` drops a name when its node leaves, and the watcher is
      # monitoring for exactly that. Nothing polls and no lease expires.
      assert_receive {:worker_started, :here}, 30_000
      assert Singleton.whereis(key) == here
    end
  end

  test "dedicated operations have one lease across nodes and fence a departed owner", ctx do
    alias Ecto.Adapters.SQL.Sandbox
    alias Ravix.Repo
    alias Ravix.Tracks.Sandbox.{Operation, Store}
    import Ravix.Factory
    import Ecto.Query

    Sandbox.unboxed_run(Repo, fn ->
      user = insert_user()
      project = insert_project(user: user)
      track = insert_track(project: project, sandbox_layout: :dedicated)

      try do
        {:ok, op} = Store.begin_operation(track.id, 0, :open)
        first = :erpc.call(ctx.node, Ravix.ClusterPeer, :claim_sandbox_operation, [op.id])
        assert first.lease
        assert Store.claim(op.id) == nil
        stop_peer(ctx.peer, ctx.node)
        assert Store.claim(op.id) == nil

        Repo.update_all(from(o in Operation, where: o.id == ^op.id),
          set: [lease_until: DateTime.add(DateTime.utc_now(), -1)]
        )

        second = Store.claim(op.id)
        refute second.lease == first.lease

        assert {:error, :lost_lease} =
                 Store.progress(first, %{phase: "setup"}, sandbox_id: "late")

        assert Store.get_track(track.id).sandbox_id == nil
        assert :erpc.call(node(), Singleton, :whereis, ["track.sandboxes"])
      after
        Repo.delete_all(from(o in Operation, where: o.track_id == ^track.id))
        Repo.delete!(track)
        Repo.delete!(project)
        Repo.delete!(user)
      end
    end)
  end

  test "a departed credential recovery worker cannot cause a second allocation", ctx do
    alias Ecto.Adapters.SQL.Sandbox
    alias Ravix.{Repo, Tracks}
    import Ravix.Factory

    Sandbox.unboxed_run(Repo, fn ->
      user = insert_user()
      project = insert_project(user: user)

      track =
        insert_track(
          project: project,
          sandbox_layout: :dedicated,
          sandbox_state: :ready,
          conversation_id: "old"
        )

      try do
        {:ok, thread} = Tracks.Store.recover_credentials(track, track.id)

        assert {:ok, claimed} =
                 :erpc.call(ctx.node, Ravix.ClusterPeer, :attempt_credential_recovery, [thread])

        stop_peer(ctx.peer, ctx.node)
        assert {:error, :stale_recovery} = Tracks.Store.attempt_credential_recovery(thread)
        assert Tracks.Store.thread(track.id).credential_recovery == claimed.credential_recovery
        assert {:ok, :ok} = Tracks.Store.bind_credential_recovery(track, claimed, "reconciled")
        assert Tracks.Store.thread(track.id).previous_conversation_ids == ["old"]
      after
        Repo.delete!(track)
        Repo.delete!(project)
        Repo.delete!(user)
      end
    end)
  end

  test "the next sweep recovers a departed node's fresh claim, but not a live node's", ctx do
    alias Ecto.Adapters.SQL.Sandbox
    alias Ravix.PromptQueue.Store
    alias Ravix.Repo
    import Ravix.Factory

    # Both instances must see committed rows; their sandbox connections cannot
    # share a transaction across BEAMs. Remove only this test's owned fixtures.
    Sandbox.unboxed_run(Repo, fn ->
      user = insert_user()
      project = insert_project(user: user)
      track = insert_track(project: project)

      try do
        {:ok, row} =
          Store.enqueue(
            track.id,
            user.id,
            user.login,
            Ecto.UUID.generate(),
            %Ravix.PromptQueue.Body{prompt: "survive the instance", images: []}
          )

        assert :erpc.call(ctx.node, Ravix.ClusterPeer, :claim_prompt, [row.id])
        claimed = Store.get(row.id)
        assert claimed.claimed_by == Atom.to_string(ctx.node)
        Store.recover()
        assert Store.get(row.id).status == :sending

        stop_peer(ctx.peer, ctx.node)
        # tick's first operation is recovery, even without a configured provider.
        server =
          start_supervised!({Ravix.PromptQueue.Server, name: nil, interval: false, wake: false})

        Sandbox.allow(Repo, self(), server)
        Ravix.PromptQueue.Server.tick(server)
        assert Store.get(row.id).status == :unconfirmed

        assert DateTime.diff(DateTime.utc_now(), claimed.claimed_at, :millisecond) <
                 Store.claim_timeout_ms()
      after
        Repo.delete!(track)
        Repo.delete!(project)
        Repo.delete!(user)
      end
    end)
  end

  test "a queued prompt holds a follower hosted on another instance", ctx do
    alias Ecto.Adapters.SQL.Sandbox
    alias Ravix.PromptQueue.{Server, Store}
    alias Ravix.Repo
    import Ravix.Factory

    Sandbox.unboxed_run(Repo, fn ->
      user = insert_user()
      project = insert_project(user: user)
      track = insert_track(project: project, conversation_id: "peer-queued")

      try do
        {:ok, row} =
          Store.enqueue(
            track.id,
            user.id,
            user.login,
            Ecto.UUID.generate(),
            %Ravix.PromptQueue.Body{prompt: "no browser", images: []}
          )

        opts = Keyword.put(follow_opts(), :conversation_id, track.conversation_id)
        {:ok, follower} = :erpc.call(ctx.node, Follower, :subscribe, [track.id, opts])
        server = start_supervised!({Server, name: nil, interval: false, wake: false})
        Sandbox.allow(Repo, self(), server)
        assert :ok = GenServer.call(server, {:heads, [row], false})
        assert Follower.whereis(track.id) == follower
        assert Map.has_key?(:sys.get_state(follower).subscribers, server)
        assert node(follower) == ctx.node
        assert :ok = GenServer.call(server, {:heads, [], false})

        assert eventually(fn ->
                 not Map.has_key?(:sys.get_state(follower).subscribers, server)
               end)

        GenServer.stop(server)
      after
        Repo.delete!(track)
        Repo.delete!(project)
        Repo.delete!(user)
      end
    end)
  end

  # ── the cluster ───────────────────────────────────────────────────────

  defp distribute!(name \\ :"ravix_primary@127.0.0.1") do
    unless Node.alive?() do
      # epmd, explicitly. The `erl` script starts it when the runtime itself is
      # given `-name` or `-sname`, but nothing starts it for a node that becomes
      # distributed later, at runtime, the way this one does. A developer
      # machine usually has one running already from some earlier `iex --name`;
      # a fresh CI runner does not, and `net_kernel.start/2` fails there with
      # `:nodistribution` and no mention of the reason.
      if epmd = System.find_executable("epmd") do
        {_output, _status} = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
      end

      {:ok, _pid} = :net_kernel.start(name, %{name_domain: :longnames})
    end

    Node.set_cookie(@cookie)
    :ok
  end

  # A peer running the whole application: the same supervision tree an instance
  # has, so the names it contends for are the real ones.
  defp start_peer! do
    {:ok, peer, node} =
      :peer.start(%{
        name: :"ravix_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(@cookie)]
      })

    true = :erpc.call(node, :code, :set_path, [:code.get_path()])
    copy_env!(node)
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:ravix], 60_000)

    # Every assertion in this file is worthless if these two are the same node
    # or are not connected, and both would fail quietly rather than loudly.
    true = node != node()
    true = node in Node.list()
    ^node = :erpc.call(node, Node, :self, [])

    # Connected is not the same as synchronised. `:global` merges name tables
    # after nodes meet, and until it has, a name registered on one of them is
    # not yet refused on the other -- a joining instance really can start a
    # duplicate for that moment (see `Ravix.Cluster`). Waited out here so these
    # tests measure the steady state rather than the join.
    :ok = :global.sync()
    :ok = :erpc.call(node, :global, :sync, [])

    {peer, node}
  end

  # Waited for, not fired and forgotten: the next test starts a node, and one
  # arriving while this one is still leaving is the churn that makes `:global`
  # start disconnecting nodes to protect itself.
  defp stop_peer(peer, node) do
    :peer.stop(peer)
    true = eventually(fn -> node not in Node.list() end)
    :ok
  catch
    # Already gone: a test that stops its peer deliberately still runs `on_exit`.
    _kind, _reason -> :ok
  end

  defp copy_env!(node) do
    for {app, _description, _version} <- Application.loaded_applications(),
        {key, value} <- Application.get_all_env(app) do
      :ok = :erpc.call(node, Application, :put_env, [app, key, value])
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────

  # Enough for a follower to start without reading a row or reaching Fountain
  # for real. What it streams is `Ravix.Tracks.FollowerTest`'s business.
  defp follow_opts do
    [
      conversation_id: "c-#{System.unique_integer([:positive])}",
      client: Client.new("http://127.0.0.1:1", "test-key"),
      stream_opts: [max_retries: 0, retry_delay: 1],
      retry_ms: 60_000,
      linger_ms: 60_000
    ]
  end

  # Holds the track's flag at `:busy` from a process that stays alive, which is
  # what an operation in flight looks like to a reader on another instance.
  # An operation in flight, without standing one up: `busy?/1` reads
  # `state.running`, so that is what is placed. The previous version registered
  # a `Ravix.Previews.Registry` entry by hand, which is the same trick against
  # the side channel that stood in for this state while the server could not
  # answer its own mailbox.
  defp hold_busy(server) do
    :sys.replace_state(server, fn state ->
      %{state | running: %{ref: make_ref(), from: {self(), make_ref()}}}
    end)

    :ok
  end

  # Re-checks the condition rather than waiting a fixed time for it: `:global`
  # removes a departed node's names when it notices, and there is no message
  # here to wait on for that.
  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end

  # One broadcast can be lost while `:pg` is still syncing the two nodes, and a
  # lost warm-up is not a failure. A lost *event* would be, which is why this
  # runs first.
  defp await_fanout(attempts \\ 100) do
    Phoenix.PubSub.broadcast(Ravix.PubSub, "ping", :ping)

    receive do
      {:forwarded, :ping} -> :ok
    after
      100 ->
        if attempts == 0,
          do: flunk("pubsub never fanned out to the peer"),
          else: await_fanout(attempts - 1)
    end
  end
end

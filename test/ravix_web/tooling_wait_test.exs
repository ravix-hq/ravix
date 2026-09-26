defmodule RavixWeb.ToolingWaitTest do
  use RavixWeb.ConnCase, async: true
  use Mimic
  import Ravix.ToolingFixture
  alias Ravix.{Fountain, Tracks}
  alias Ravix.PromptQueue.Store, as: QueueStore
  alias Ravix.Tooling.Tasks
  alias Ravix.Tracks.Follower

  defmodule Front do
    alias RavixWeb.Tooling.Wait
    def init(opts), do: opts

    def call(conn, opts) do
      Process.put(:"$callers", [opts[:owner]])
      send(opts[:owner], {:request, self()})
      Wait.call(conn, opts[:principal], opts[:params])
    end
  end

  test "closing an HTTP client releases the waiter and its provider read" do
    owner = self()
    user = insert_user()

    track =
      insert_track(project: insert_project(user: user), conversation_id: Ecto.UUID.generate())

    {p, _, _} = principal(user)
    stub(Fountain, :client, fn -> Fountain.Client.new("https://fountain.test", "key") end)
    {:ok, task} = Tasks.send(p, track.id, "hello", "disconnect")
    QueueStore.mark_delivered(task.id)

    stub(Tracks, :follow, fn _, _, opts ->
      Phoenix.PubSub.subscribe(Ravix.PubSub, Follower.topic(opts[:thread_id]))
      send(owner, {:subscribed, self()})
      {:ok, owner}
    end)

    stub(Fountain, :turns, fn _, _ ->
      send(owner, {:refresh, self()})

      receive do
        :never -> {:ok, []}
      end
    end)

    params = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "wait_task",
        "arguments" => %{"task_ids" => [task.id], "timeout_ms" => 50_000}
      }
    }

    server =
      start_supervised!(
        {Bandit,
         plug: {Front, [owner: owner, principal: p, params: params]}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")
    assert_receive {:request, _}, 1000
    assert_receive {:subscribed, waiter}, 1000
    assert_receive {:refresh, worker}, 1000
    waiter_ref = Process.monitor(waiter)
    worker_ref = Process.monitor(worker)
    :ok = :inet.setopts(socket, linger: {true, 0})
    :gen_tcp.close(socket)
    assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, _}, 2500
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 2500

    refute Enum.any?(Registry.lookup(Ravix.PubSub, Follower.topic(track.id)), fn {pid, _} ->
             pid == waiter
           end)
  end
end

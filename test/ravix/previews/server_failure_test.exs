defmodule Ravix.Previews.ServerFailureTest do
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic
  import Ravix.PreviewsFixture
  alias Ravix.{Previews, Tracks}
  alias Ravix.Previews.Server

  setup do
    provider = start_provider()
    stub_provider(provider)
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation")
    %{user: user, project: project, track: track}
  end

  test "a missing configuration fails visibly and remains retryable", ctx do
    assert :ok = Previews.start_service(ctx.track.id)
    assert %{state: :failed, error: message} = Previews.info(ctx.track.id)
    assert message =~ "Save a preview startup command"
  end

  test "a missing machine explains how to recover", ctx do
    configure(ctx)
    stub(Tracks, :machine_of, fn _, _ -> {:ok, nil} end)
    assert :ok = Previews.start_service(ctx.track.id)
    assert %{state: :failed, error: message} = Previews.info(ctx.track.id)
    assert message =~ "Open a track first"
  end

  test "provider errors settle startup instead of leaving the preview starting", ctx do
    configure(ctx)
    stub(Tracks, :machine_of, fn _, _ -> {:error, {:unavailable, "Fountain is offline"}} end)
    assert :ok = Previews.start_service(ctx.track.id)
    assert %{state: :failed, error: "Fountain is offline"} = Previews.info(ctx.track.id)
    refute Server.busy?(ctx.track.id)
  end

  test "an operation in flight reads as busy, and idle again once it settles", ctx do
    configure(ctx)
    test_pid = self()

    stub(Tracks, :machine_of, fn _, _ ->
      send(test_pid, {:in_flight, self()})
      receive do: (:go -> :ok)
      {:error, {:unavailable, "Fountain is offline"}}
    end)

    task = Task.async(fn -> Previews.start_service(ctx.track.id) end)
    assert_receive {:in_flight, worker}, 5_000

    # The flag `Ravix.Previews.Reconciler` reads before queueing an `:ensure`
    # behind an operation already running on this sprite -- and, on another
    # instance, the one it fetches over `:erpc`. The server registers it on its
    # first operation rather than at startup, so a regression there would leave
    # every track looking permanently idle.
    assert Server.busy?(ctx.track.id)

    send(worker, :go)
    assert :ok = Task.await(task)
    refute Server.busy?(ctx.track.id)
  end

  @tag capture_log: true
  test "a caller is answered when the task running its operation is killed", ctx do
    # The guarantee the queue-and-task shape buys. `run/2` waits `:infinity`,
    # so an operation that dies without reporting used to be a caller blocked
    # for the life of the process -- and, while the work ran inside
    # `handle_call/3`, it took the server and everything queued behind it down
    # with it.
    configure(ctx)
    test_pid = self()

    stub(Tracks, :machine_of, fn _, _ ->
      send(test_pid, {:in_flight, self()})
      Process.sleep(:infinity)
    end)

    caller = Task.async(fn -> Previews.start_service(ctx.track.id) end)
    assert_receive {:in_flight, worker}, 5_000

    server = Server.ensure(ctx.track.id)
    Process.exit(worker, :kill)

    assert {:error, :preview_operation_down} = Task.await(caller, 5_000)

    # The server survived it and is ready for the next operation.
    assert Process.alive?(server)
    refute Server.busy?(ctx.track.id)
  end

  test "a server that cannot answer in time counts as busy, so no work is queued behind it" do
    # The reconciler's only question is whether to queue an `:ensure` behind an
    # operation it cannot see. A server that does not answer might have been
    # about to say yes, and "leave this track alone for fifteen seconds" is the
    # only answer that cannot start a second operation on the same sprite.
    #
    # This needed a second BEAM while the answer came back over `:erpc` from
    # the owning instance. It is a `GenServer.call/3` now, so an unanswerable
    # one is an unanswerable one wherever the process is.
    track_id = Ecto.UUID.generate()
    mute = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(mute, :kill) end)

    :yes = :global.register_name(Ravix.Cluster.name(:preview, track_id), mute)
    assert Server.busy?(track_id)
  end

  test "idle preview processes stop and can be recreated", ctx do
    pid = Server.ensure(ctx.track.id)
    send(pid, :unrelated)
    assert Process.alive?(pid)
    monitor = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    replacement = Server.ensure(ctx.track.id)
    assert replacement != pid
    assert :ok = Server.stop(ctx.track.id)
    refute Process.alive?(replacement)
    assert :ok = Server.stop(ctx.track.id)
  end

  @tag capture_log: true
  test "an unexpected provider exception clears the busy marker", ctx do
    configure(ctx)
    stub(Tracks, :machine_of, fn _, _ -> raise "unexpected failure" end)

    assert {:error, %RuntimeError{message: "unexpected failure"}} =
             Previews.start_service(ctx.track.id)

    refute Server.busy?(ctx.track.id)
  end

  defp configure(ctx) do
    {:ok, _} =
      Previews.set_defaults(ctx.user, ctx.project.id, %{
        directory: ".",
        command: "npm start",
        readiness_path: "/"
      })
  end
end

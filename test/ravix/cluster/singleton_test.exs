defmodule Ravix.Cluster.SingletonTest do
  @moduledoc """
  Acquisition, takeover and teardown on one node. Two watchers on one node
  behave exactly as two watchers on two nodes do -- the name they contend for is
  the same one -- so only the parts that genuinely need a second BEAM live in
  `Ravix.Cluster.DistributionTest`.
  """
  use ExUnit.Case, async: true

  alias Ravix.Cluster.Singleton

  defp key, do: "singleton-#{System.unique_integer([:positive])}"

  # A worker that announces itself and then stays up, so a test can tell both
  # that it started and when it stopped.
  defp worker(ref) do
    parent = self()

    {Task,
     fn ->
       send(parent, {:worker_started, ref, self()})
       Process.sleep(:infinity)
     end}
  end

  # The id comes back with the pid because a test that "stops an instance" has
  # to stop it through the supervisor. `GenServer.stop/1` on a supervised child
  # is a crash from the supervisor's point of view, and it restarts it -- which
  # then races the takeover this is trying to observe.
  defp start_watcher(key, ref) do
    id = {:singleton, make_ref()}
    {start_supervised!({Singleton, key: key, child: worker(ref)}, id: id), id}
  end

  test "the instance that gets the name runs the worker" do
    key = key()
    ref = make_ref()

    {watcher, _id} = start_watcher(key, ref)

    assert_receive {:worker_started, ^ref, _worker}, 5_000
    assert Singleton.holding?(watcher)
    assert Singleton.whereis(key) == watcher
  end

  test "a second instance does not, and the worker runs once" do
    key = key()
    first_ref = make_ref()
    second_ref = make_ref()

    {first, _} = start_watcher(key, first_ref)
    assert_receive {:worker_started, ^first_ref, _}, 5_000

    {second, _} = start_watcher(key, second_ref)

    assert Singleton.holding?(second) == false
    refute_receive {:worker_started, ^second_ref, _}, 500
    assert Singleton.whereis(key) == first
  end

  test "the survivor takes over when the holder goes away" do
    key = key()
    first_ref = make_ref()
    second_ref = make_ref()

    {_first, first_id} = start_watcher(key, first_ref)
    assert_receive {:worker_started, ^first_ref, first_worker}, 5_000

    {second, _} = start_watcher(key, second_ref)
    assert Singleton.holding?(second) == false

    # Standing in for the instance leaving: `:global` releases the name either
    # way, and the survivor is watching for exactly that.
    :ok = stop_supervised!(first_id)

    assert_receive {:worker_started, ^second_ref, _}, 5_000
    assert Singleton.whereis(key) == second

    # And the first worker is gone rather than orphaned: a `:normal` exit
    # signal would not have stopped it, so the singleton stops it explicitly.
    refute Process.alive?(first_worker)
  end

  test "standing down after a name merge stops the worker without a crash" do
    key = key()
    ref = make_ref()

    {watcher, _id} = start_watcher(key, ref)
    assert_receive {:worker_started, ^ref, worker}, 5_000
    assert Singleton.holding?(watcher)

    watching = Process.monitor(watcher)

    # What `:global` does when two instances that could not see each other meet:
    # it keeps one registration, drops the other, and tells the loser. Replayed
    # here in that order. With the default resolver the loser would simply be
    # killed, and a supervised child being killed on every instance join is an
    # outage rather than a hiccup -- so what matters is that this one survives.
    winner = start_supervised!({Agent, fn -> :winner end}, id: {:winner, key})
    :global.unregister_name(Ravix.Cluster.name(:singleton, key))
    :yes = :global.register_name(Ravix.Cluster.name(:singleton, key), winner)
    send(watcher, {:global_name_conflict, Ravix.Cluster.name(:singleton, key)})

    refute_receive {:DOWN, ^watching, :process, ^watcher, _reason}, 500
    refute Singleton.holding?(watcher)
    refute Process.alive?(worker)
    assert Singleton.whereis(key) == winner
  end

  test "a worker that will not start releases the name instead of holding it idle" do
    key = key()

    # Holding the name while running nothing is the one outcome worse than
    # failing: no other instance could take the work either, and nothing would
    # say so. So this exits, its supervisor restarts it, and the name is free
    # for whichever instance can actually run the worker.
    watcher =
      start_supervised!(
        {Singleton, key: key, child: {Agent, fn -> raise "this worker cannot start" end}},
        id: {:singleton, make_ref()},
        restart: :temporary
      )

    # The exit reason is not asserted on purpose: the watcher may already be
    # gone by the time this monitor is set, in which case the runtime reports
    # `:noproc` and says nothing about why. What has to hold either way is the
    # contract -- the watcher is not running and the name is free.
    watching = Process.monitor(watcher)

    assert_receive {:DOWN, ^watching, :process, ^watcher, _reason}, 5_000
    assert Singleton.whereis(key) == nil
  end

  test "an unrelated message leaves the watcher and its worker alone" do
    key = key()
    ref = make_ref()

    {watcher, _id} = start_watcher(key, ref)
    assert_receive {:worker_started, ^ref, worker}, 5_000

    send(watcher, :something_else)

    assert Singleton.holding?(watcher)
    assert Process.alive?(worker)
  end

  test "a worker that dies takes its watcher with it, so the work can move" do
    key = key()
    ref = make_ref()

    {watcher, _id} = start_watcher(key, ref)
    assert_receive {:worker_started, ^ref, worker}, 5_000

    watching = Process.monitor(watcher)
    Process.exit(worker, :kill)

    assert_receive {:DOWN, ^watching, :process, ^watcher, _reason}, 5_000

    # The name went with it, which is what lets another instance pick it up.
    assert Singleton.whereis(key) != watcher
  end
end

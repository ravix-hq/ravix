defmodule Ravix.ClusterTest do
  @moduledoc """
  The naming itself, on one node. What `:global` adds across nodes is covered by
  `Ravix.Cluster.DistributionTest`, which pays for real peers to prove it.
  """
  use ExUnit.Case, async: true

  alias Ravix.Cluster

  # Unique per test: these are cluster-wide names, and this suite is async.
  defp key, do: "key-#{System.unique_integer([:positive])}"

  defp start_named(key) do
    pid = start_supervised!({Agent, fn -> :held end}, id: {:agent, key})
    :yes = :global.register_name(Cluster.name(:preview, key), pid)
    pid
  end

  describe "name/2" do
    test "is scoped to Ravix, so nothing else sharing a cluster can collide" do
      assert Cluster.name(:follower, "t1") == {:ravix, :follower, "t1"}
      assert Cluster.name(:preview, "t1") != Cluster.name(:follower, "t1")
    end
  end

  describe "via/2" do
    test "names a process for the whole cluster, and refuses a second under the same name" do
      key = key()

      assert {:ok, first} = Agent.start_link(fn -> :first end, name: Cluster.via(:follower, key))

      # The refusal is the point: a local registry would have let the second one
      # start and then had two followers broadcasting the same events.
      assert {:error, {:already_started, ^first}} =
               Agent.start_link(fn -> :second end, name: Cluster.via(:follower, key))

      assert Cluster.whereis(:follower, key) == first
    end

    test "different keys in one scope are different processes" do
      one = key()
      two = key()

      {:ok, first} = Agent.start_link(fn -> :ok end, name: Cluster.via(:follower, one))
      {:ok, second} = Agent.start_link(fn -> :ok end, name: Cluster.via(:follower, two))

      assert first != second
      assert Cluster.whereis(:follower, one) == first
      assert Cluster.whereis(:follower, two) == second
    end
  end

  describe "whereis/2" do
    test "nil when nobody holds the name" do
      assert Cluster.whereis(:preview, key()) == nil
    end

    test "the holder while it lives" do
      key = key()
      pid = start_named(key)

      assert Cluster.whereis(:preview, key) == pid
    end

    test "nil again once the holder exits, which is how liveness is answered" do
      key = key()
      pid = start_named(key)
      ref = Process.monitor(pid)

      :ok = Agent.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # `:global` drops the name itself; nothing here polls for it. Not
      # instantaneous, though, which is why callers still tolerate a stale pid.
      assert eventually(fn -> Cluster.whereis(:preview, key) == nil end)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end

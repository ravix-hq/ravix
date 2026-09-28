defmodule Ravix.ReleaseTest do
  @moduledoc """
  A release task starts what it needs and no more.

  `bin/ravix eval` runs a node beside production that is not in its cluster,
  so a task there that started the whole application would run a second copy
  of every `Ravix.Cluster.Singleton` -- which, seeing no cluster, would defer
  to nobody. Only a node where `:ravix` has never started can show that, so
  the task runs in a peer: not distributed, `nonode@nohost`, exactly as
  `eval` runs it. Tagged `:distributed` with the other suites that start one.
  """
  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag :capture_log
  @moduletag timeout: 120_000

  setup do
    {:ok, peer, _node} = :peer.start(%{connection: :standard_io})
    on_exit(fn -> stop(peer) end)

    :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])

    for {app, _description, _version} <- Application.loaded_applications(),
        {key, value} <- Application.get_all_env(app) do
      :ok = :peer.call(peer, Application, :put_env, [app, key, value])
    end

    %{peer: peer}
  end

  test "a task starts the Repo and its clients, and no singleton, scheduler or endpoint",
       %{peer: peer} do
    snapshot = :peer.call(peer, Ravix.ClusterPeer, :release_task, [:provider_secrets, []], 60_000)

    # The task ran, against the database.
    assert is_integer(snapshot.result)
    assert snapshot.output != ""
    assert snapshot.repo == [[1]]
    assert Ravix.PubSub in snapshot.registered
    assert Ravix.GitHub.Cache in snapshot.registered

    # And the application did not.
    refute snapshot.ravix_started?
    refute Ravix.Supervisor in snapshot.registered
    refute RavixWeb.Endpoint in snapshot.registered
    refute Ravix.Tracks.Follower.Supervisor in snapshot.registered
    refute {Ravix.Cluster.Singleton, :init, 1} in snapshot.initial_calls
  end

  # Already gone is fine: the peer is linked to the test process.
  defp stop(peer) do
    :peer.stop(peer)
  catch
    :exit, _ -> :ok
  end
end

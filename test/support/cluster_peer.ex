defmodule Ravix.ClusterPeer do
  @moduledoc """
  What a peer node runs on behalf of `Ravix.Cluster.DistributionTest`.

  It lives here rather than in the test file because a peer resolves code
  through the shared code path, and `test/support` is compiled to a `.beam` that
  the path includes. A test module is not: its code is only ever loaded in the
  node that ran the `.exs`, so a closure defined there arrives on the peer as an
  `UndefinedFunctionError`. Named functions in a compiled module cross cleanly.
  """

  alias Ravix.Cluster.Singleton

  @doc """
  Subscribe to `topics` on this node and forward everything that arrives to
  `parent` as `{:forwarded, message}`. Announces itself first, so the test knows
  the subscription is in place before it broadcasts.
  """
  @spec reader(pid(), [String.t()]) :: no_return()
  def reader(parent, topics) do
    Enum.each(topics, &Phoenix.PubSub.subscribe(Ravix.PubSub, &1))
    send(parent, {:ready, self()})
    forward(parent)
  end

  defp forward(parent) do
    receive do
      message ->
        send(parent, {:forwarded, message})
        forward(parent)
    end
  end

  @doc """
  Hold a cluster singleton on this node until the node goes away.

  The worker announces itself to `parent` tagged `:peer`, which is how a test
  tells "the peer is running it" from "this node took it over".
  """
  @spec hold_singleton(pid(), String.t()) :: no_return()
  def hold_singleton(parent, key) do
    {:ok, _watcher} = Singleton.start_link(key: key, child: worker(parent, :peer))
    Process.sleep(:infinity)
  end

  @doc "A worker that says it started and then stays up."
  @spec worker(pid(), term()) :: {module(), (-> no_return())}
  def worker(parent, tag) do
    {Task,
     fn ->
       send(parent, {:worker_started, tag})
       Process.sleep(:infinity)
     end}
  end

  @doc """
  Announce somebody on a track from this node, then stay alive holding them
  there. Presence is the process, so the beat only stands while this lives.
  """
  @spec beat_and_hold(String.t(), String.t(), Ravix.Accounts.User.t()) :: no_return()
  def beat_and_hold(track_id, project_id, user) do
    Ravix.Presence.beat(track_id, project_id, user, false)
    Process.sleep(:infinity)
  end
end

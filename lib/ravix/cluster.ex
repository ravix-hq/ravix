defmodule Ravix.Cluster do
  @moduledoc """
  Names that mean the same process on every instance.

  Ravix runs as more than one instance in one region (ADR 0003), and two of its
  process families must not exist twice: `Ravix.Tracks.Follower`, because it
  broadcasts Fountain's transcript to a PubSub topic that spans the cluster and
  a second copy would deliver every event twice, and `Ravix.Previews.Server`,
  because it is the lock that keeps starts, stops and rebuilds of one preview
  from overlapping on a sprite.

  A local `Registry` cannot say that. `:global` can: `register_name/2` takes a
  cluster-wide lock, so the second instance to try a name is told the first one
  won rather than finding an empty registry and starting a duplicate. That
  synchronous lock is the point, and it is why this is not a CRDT registry --
  an eventually consistent lookup answers "nobody has this name" during the
  window that matters, which is exactly how two sprites get provisioned for one
  conversation. Fountain carries a polling settle window
  (`ConversationServer.await_registered/2`) for precisely that race.

  What `:global` does not do is move a process when its node dies; the name is
  simply released. That is deliberate here. A follower with no subscribers
  should not exist -- its subscribers were on the node that just died -- and
  `Ravix.Previews.Reconciler` already restores what the database says should be
  running within its next pass. The reader's own recovery is a monitor, in
  `RavixWeb.TrackLive`, because only the reader knows which event id it holds.

  Supervision stays node-local: whichever instance needs a process starts it
  under its own `DynamicSupervisor`, and the name makes it reachable from
  everywhere. Names are `{:ravix, scope, key}` so nothing else sharing a
  cluster could collide with them.
  """

  @typedoc "The process family a name belongs to."
  @type scope :: :follower | :preview | :singleton

  @doc """
  The `:global` name for a scope and key.

  Public because `Ravix.Cluster.Singleton` registers and monitors a name
  directly rather than through a `GenServer` via-tuple.
  """
  @spec name(scope(), String.t()) :: {:ravix, scope(), String.t()}
  def name(scope, key), do: {:ravix, scope, key}

  @doc """
  A name to start a process under, cluster-wide.

  `GenServer.start_link(mod, arg, name: Ravix.Cluster.via(:follower, id))`
  returns `{:error, {:already_started, pid}}` when another instance holds the
  name, and that `pid` is on that instance. Callers already handle the tuple;
  what changes in a cluster is that the pid can be remote.
  """
  @spec via(scope(), String.t()) :: {:via, module(), {:ravix, scope(), String.t()}}
  def via(scope, key), do: {:via, :global, name(scope, key)}

  @doc """
  The process holding a name anywhere in the cluster, or `nil`.

  No `Process.alive?/1` check: it answers only for a local pid, and `:global`
  drops a name when its process exits or its node goes away, so the absence of
  a name is the liveness answer.
  """
  @spec whereis(scope(), String.t()) :: pid() | nil
  def whereis(scope, key) do
    case :global.whereis_name(name(scope, key)) do
      :undefined -> nil
      pid when is_pid(pid) -> pid
    end
  end
end

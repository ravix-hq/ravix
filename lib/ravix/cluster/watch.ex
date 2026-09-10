defmodule Ravix.Cluster.Watch do
  @moduledoc """
  Says who this instance can see, in the log, whenever that changes.

  Clustering is the one thing here that fails silently. An instance whose
  `RELEASE_COOKIE` does not match its siblings', or whose `RELEASE_DISTRIBUTION`
  never became `name`, boots, serves, answers `/readyz`, and passes every health
  check there is — while running its own transcript follower for every open
  track and its own copy of work that is supposed to happen once (ADR 0003).
  Nothing about the outside of such an instance looks wrong.

  Until now the only way to know was `Node.list/0` from a remote shell, which is
  not available on a service with shell access turned off — and an invariant you
  cannot check on the deployment you actually run is not much of an invariant.
  So membership is written to the log: once at startup, and then on every join
  and every departure.

  Deliberately cheap and deliberately quiet. `:net_kernel.monitor_nodes/1` is a
  message per change and nodes change when instances deploy or die, so this is
  a handful of lines per deploy rather than a stream. It reports and does not
  act: reconnection is `DNSCluster`'s job, takeover is
  `Ravix.Cluster.Singleton`'s, and a watcher that also tried to fix things would
  be a second opinion about cluster membership, which is the last thing a
  cluster needs.

  The startup line is scheduled rather than immediate. `DNSCluster` resolves and
  connects after the supervision tree is up, so an instance logging its peers at
  `init/1` would always say "alone" and teach everyone to ignore the line.
  """

  use GenServer

  require Logger

  # Long enough for DNSCluster's first resolve and connect, short enough that
  # somebody watching a deploy sees the answer while still watching.
  @settle_ms 15_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Who this instance can see right now. The log is the same list."
  @spec peers() :: [node()]
  def peers, do: Node.list()

  @impl true
  def init(opts) do
    :net_kernel.monitor_nodes(true)
    Process.send_after(self(), :report, Keyword.get(opts, :settle_ms, @settle_ms))
    {:ok, %{}}
  end

  @impl true
  def handle_info(:report, state) do
    case Node.list() do
      [] ->
        # Not necessarily wrong -- one instance is a legitimate deployment, and
        # every developer machine is one. Said at :info, not :warning, because
        # the operator knows which they are running and a false alarm on every
        # local boot is how a real one gets ignored.
        Logger.info("ravix: cluster of one; #{node()} sees no peers")

      peers ->
        Logger.info("ravix: clustered; #{node()} sees #{inspect(peers)}")
    end

    {:noreply, state}
  end

  def handle_info({:nodeup, node}, state) do
    Logger.info("ravix: #{node} joined; now #{inspect(Node.list())}")
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    # An instance leaving is ordinary during a deploy and worth noticing at any
    # other time, which is why it says what is left rather than only what went.
    Logger.info("ravix: #{node} left; now #{inspect(Node.list())}")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end

defmodule Ravix.Cluster.Singleton do
  @moduledoc """
  One instance runs the worker; the others wait to take it over.

  Some work must happen on a timer and must not happen twice.
  `Ravix.Previews.Reconciler` is the case this exists for: its pass is "for
  every row, in parallel across tracks and never twice for one track", and on
  three instances the fifteen-second tick would be three passes making the same
  decisions about the same sprites.

  Every instance starts one of these per wrapped worker. It tries to register a
  `:global` name; the one that gets it starts the worker as a **linked** child
  and the rest monitor the holder and try again when it goes away. `:global`
  releases a name when its process exits or its node leaves the cluster, and a
  cross-node monitor fires on a disconnect, so a takeover needs no polling and
  no lease to expire.

  Linked rather than supervised on purpose: a worker that crashes takes this
  process with it, the node's own supervisor restarts this process, and it
  re-acquires — the same restart exposure the worker had when it was a direct
  child of `Ravix.Supervisor`, plus the possibility that a different instance
  picks the work up. Nothing is handed over, because nothing is held: the
  worker's state is the database.

  Exits are trapped, which is what makes "linked" safe in both directions. A
  link alone would not do: a `:normal` exit signal does not stop a linked
  process, so stopping this one cleanly would leave the worker running and
  unowned while another instance took the name and started a second. So the
  worker is stopped explicitly and waited for, and only then is the name free.

  Two instances really can both hold the name for a moment: `:global` merges
  name tables *after* nodes meet, so an instance that has just joined does not
  yet know what its new siblings have registered — during a deploy, that is
  every new instance. What happens next is the reason this registers with
  `:global.random_notify_name/3` instead of the default resolver. The default,
  `random_exit_name/3`, **kills** the loser; here that is a supervised child, so
  it would be restarted, re-acquire, and be killed again, and enough of that in
  five seconds takes `Ravix.Supervisor` and the whole instance down with it. The
  notifying resolver sends `{:global_name_conflict, name}` instead, which this
  process handles by stopping its worker and going back to watching. A duplicate
  therefore costs one redundant tick, not an outage.

  Not for work that is merely *cheaper* done once. `Ravix.PromptQueue.Server`
  deliberately keeps sweeping on every instance: its claim is a conditional
  `UPDATE`, so a duplicate sweep cannot double-deliver, and prompt delivery is
  worth more than a takeover window (ADR 0003).

      {Ravix.Cluster.Singleton, key: "previews.reconciler", child: Ravix.Previews.Reconciler}
  """

  use GenServer

  require Logger

  alias Ravix.Cluster

  # Only for the case below where the holder vanishes between a refused
  # registration and the lookup for it. Long enough not to spin.
  @settle_ms 100
  # How long a worker gets to stop before it is killed, on the way out.
  @shutdown_ms 5_000

  @typedoc "`:key` names the singleton cluster-wide; `:child` is the worker's child spec."
  @type option ::
          {:key, String.t()} | {:child, Supervisor.child_spec() | module() | {module(), term()}}

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :key)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Start the watcher on this instance. See the module for the options."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {key, opts} = Keyword.pop!(opts, :key)
    {child, opts} = Keyword.pop!(opts, :child)
    GenServer.start_link(__MODULE__, {key, child}, opts)
  end

  @doc "The process holding `key` anywhere in the cluster, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(key), do: Cluster.whereis(:singleton, key)

  @doc "Whether this instance is the one running `key`'s worker."
  @spec holding?(GenServer.server()) :: boolean()
  def holding?(server), do: GenServer.call(server, :holding?)

  # ── callbacks ─────────────────────────────────────────────────────────

  @impl true
  def init({key, child}) do
    Process.flag(:trap_exit, true)

    # Acquiring takes a cluster-wide lock, so it happens after `init/1` returns:
    # a slow one would hold up the whole application's boot.
    {:ok, %{key: key, spec: child, child: nil}, {:continue, :acquire}}
  end

  @impl true
  def handle_continue(:acquire, state), do: {:noreply, acquire(state)}

  @impl true
  def handle_call(:holding?, _from, state), do: {:reply, is_pid(state.child), state}

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, acquire(state)}
  def handle_info(:acquire, state), do: {:noreply, acquire(state)}

  # The worker died. Go with it: the node's supervisor restarts this process,
  # which releases the name on the way out, so whichever instance gets there
  # first starts the next one. An exit from anything else is not ours to act on.
  def handle_info({:EXIT, child, reason}, %{child: child} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  # `:global` merged two registrations of this name and kept the other one. Not
  # an error and not a crash: stop the worker so the instance that kept the name
  # is the only one running it, and go back to watching.
  def handle_info({:global_name_conflict, _name}, state) do
    Logger.info("ravix: singleton #{state.key} stood down to another instance")
    {:noreply, state |> stop_child() |> acquire()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_child(state)
    :ok
  end

  # ── acquiring ─────────────────────────────────────────────────────────

  defp acquire(%{child: child} = state) when is_pid(child), do: state

  defp acquire(state) do
    # `random_notify_name/3` rather than the default resolver: see the module
    # docs. Losing a merge must not be fatal.
    case :global.register_name(
           Cluster.name(:singleton, state.key),
           self(),
           &:global.random_notify_name/3
         ) do
      :yes -> start_child(state)
      :no -> watch(state)
    end
  end

  # Stopped explicitly and waited for: a link alone would not do it (a `:normal`
  # exit signal does not stop a linked process), and returning before the worker
  # is gone would let the next one start beside it.
  defp stop_child(%{child: child} = state) when is_pid(child) do
    ref = Process.monitor(child)
    Process.exit(child, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^child, _reason} -> :ok
    after
      @shutdown_ms -> Process.exit(child, :kill)
    end

    %{state | child: nil}
  end

  defp stop_child(state), do: state

  defp start_child(state) do
    %{start: {module, function, args}} = Supervisor.child_spec(state.spec, [])

    case apply(module, function, args) do
      {:ok, child} ->
        # Which instance runs it, in the log. Two instances both claiming the
        # same key is the failure this whole module exists to prevent, and on a
        # deployment without shell access the log is the only place it shows.
        Logger.info("ravix: singleton #{state.key} running on #{node()}")
        %{state | child: child}

      other ->
        # Holding the name without running the worker would stop any other
        # instance from running it either, which is the one outcome worse than
        # crashing here.
        :global.unregister_name(Cluster.name(:singleton, state.key))
        Logger.error("ravix: singleton #{state.key} could not start: #{inspect(other)}")
        exit({:singleton_child_failed, state.key, other})
    end
  end

  defp watch(state) do
    case whereis(state.key) do
      nil ->
        # It exited between the refused registration and this lookup. Nothing
        # will report a death we never saw, so ask again shortly.
        Process.send_after(self(), :acquire, @settle_ms)
        state

      holder ->
        Process.monitor(holder)
        state
    end
  end
end

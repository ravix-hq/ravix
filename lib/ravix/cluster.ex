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

  @typedoc "The process family a name (or, for `:settlement_scan`, a lock) belongs to."
  @type scope ::
          :follower | :preview | :singleton | :settlement | :settlement_scan | :reply_backfill

  @doc """
  The `:global` name for a scope and key.

  Public because `Ravix.Cluster.Singleton` registers and monitors a name
  directly rather than through a `GenServer` via-tuple.
  """
  @spec name(scope(), String.t()) :: {:ravix, scope(), String.t()}
  def name(scope, key), do: {:ravix, scope, key}

  @doc """
  Exclude overlapping project mutations across connected instances without
  checking out a database connection. Only opt-in lifecycle paths use this.
  The caller owns the lock; process/node loss releases it. Durable fences
  remain in the database after the critical section ends.
  """
  @spec project_mutation(
          String.t(),
          :shared_machine | :secret_change | :env_vars_change,
          (-> term())
        ) :: term()
  def project_mutation(project_id, kind, fun) do
    lock = {{:ravix, :project_mutation, kind, project_id}, self()}
    nodes = [node() | Node.list()]

    if :global.set_lock(lock, nodes, 0) do
      try do
        fun.()
      after
        :global.del_lock(lock, nodes)
      end
    else
      {:error,
       {:conflict, "project_change_in_progress",
        "Another change to this project's machine, secrets or variables is still running. Try again shortly."}}
    end
  end

  @doc """
  Serialize every read-modify-write of one Fountain agent's
  `allowed_inference_credential_ids` across connected instances.

  Fountain replaces the whole list on `PUT /api/agents/:id` and has no
  conditional update, so two admissions racing each other would each write
  the list they read and the later one would drop the earlier one's set
  (`docs/creator-billing.md` §1). Unlike `project_mutation/3` this waits a
  little for the holder, whose critical section is two or three short
  Fountain calls, then fails closed: an admission that cannot take the lock
  is an admission that did not happen.
  """
  @spec agent_allowlist(String.t(), (-> term())) :: term()
  def agent_allowlist(agent_id, fun) when is_binary(agent_id) do
    lock = {{:ravix, :agent_allowlist, agent_id}, self()}
    nodes = [node() | Node.list()]
    wait = Application.get_env(:ravix, :agent_allowlist_wait_ms, 5_000)

    if take_lock(lock, nodes, System.monotonic_time(:millisecond) + wait) do
      try do
        fun.()
      after
        :global.del_lock(lock, nodes)
      end
    else
      {:error,
       {:conflict, "payer_admission_busy",
        "Another change to this project's agent is still running. Your prompt is saved; try again shortly."}}
    end
  end

  # `:global`'s own retries back off to seconds apiece; a short fixed poll
  # bounded by a deadline keeps the wait what the caller can afford.
  defp take_lock(lock, nodes, deadline) do
    cond do
      :global.set_lock(lock, nodes, 0) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        take_lock(lock, nodes, deadline)
    end
  end

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

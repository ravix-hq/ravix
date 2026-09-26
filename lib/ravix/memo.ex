defmodule Ravix.Memo do
  @moduledoc """
  A read-through memo where concurrent misses share one load.

  Two of these were written independently -- `Ravix.MachineCache` for
  Fountain's conversation list, `Ravix.GitHub.Cache` for checks reports --
  and they agreed about the hard parts because the hard parts are forced:

    * **Hits never touch the server.** Values live in a public ETS table, so
      a cache that is doing its job costs one `:ets.lookup/2` and no message.
    * **Misses coalesce.** The first caller starts the load; everyone who
      arrives while it runs is parked and answered from the same result. A
      cache that does not do this turns twenty mounted rows into twenty
      requests, which is the thing it was added to prevent.
    * **An invalidation still answers.** Forgetting a key while a load is in
      flight must not strand the callers waiting on it, *and* must not let
      that load write its answer afterwards: it was started before whatever
      invalidated the key, so its answer is already out of date. Waiters get
      it, because it is the best answer that exists; the table does not.
    * **A crash is an answer.** If the load raises, or the process running it
      dies, every waiter is replied to. Nothing here may leave a caller
      blocked on a `GenServer.call/3` that will never return.
    * **A refresh is not a forget.** A caller that wants a value no older
      than a moment says so with `:newer_than` and is answered by a load
      that started at or after it: the held value if it is that new, the
      load in flight if *it* is, and otherwise the one load that starts
      when the in-flight one settles. `Ravix.MachineCache` used to forget
      the key first and then fetch, which disowned whatever load was
      running and started another; a hub event that reached twenty pages
      cost twenty loads of the same list instead of one or two.

  Getting all five right once is worth doing; getting them right twice, and
  keeping them right in two places as they change, is not.

  ## What the two callers did differently

  Both differences are options rather than forks, because both are real.

  `:run` says who executes the load. `:task` runs it under
  `Ravix.TaskSupervisor` and is the default: the caller waits on a
  `GenServer.call/3` while a supervised task does the work, so a slow
  provider blocks the waiters and nobody else. `:caller` hands the work back
  to the first caller to run in its own process, which `Ravix.GitHub.Cache`
  needs because the read must see that caller's `Req.Test` stubs.

  `:expires_at` computes when a result stops being good, given the result
  and the millisecond the load *started*. Taking the start rather than the
  finish is what stops a value's lifetime being stretched by however long
  the provider took; a caller that wants absolute expiry from elsewhere (a
  rate limit's reset, say) can ignore the argument. Returning `nil` means
  "answer the waiters but remember nothing", which is how a failed read
  stays unremembered.

  ## When a load started

  Every entry remembers the millisecond its load started, on the caller's
  clock, and `:newer_than` is compared against that. A caller arriving with
  `:newer_than` later than the running load's start does not join it -- that
  load may have asked the provider before whatever the caller has just
  heard about happened -- and does not start a second one beside it either.
  It is parked as a *follower*: when the running load settles, one load
  starts for every follower at once, so a burst of refreshes costs at most
  the load in flight and one more, however many pages are refreshing. The
  follow-up is stamped with the latest follower's clock, which is at or
  before the moment it actually starts: an entry may under-claim its age
  and be re-read a little early, but never over-claim it and be trusted
  late.
  """

  use GenServer

  alias Ravix.Trace

  @type key :: term()
  @type result :: term()

  @typedoc """
  Options for `fetch/5`.

    * `:now_ms` -- the caller's clock, so tests can move it.
    * `:newer_than` -- accept no value whose load started before this
      millisecond; see "When a load started" above.
    * `:run` -- `:task` (default) or `:caller`; see the module documentation.
    * `:on_crash` -- called with the exit reason or exception, and must
      return the result every waiter gets. Defaults to `{:error, reason}`.
  """
  @type option ::
          {:now_ms, integer()}
          | {:newer_than, integer() | nil}
          | {:run, :task | :caller}
          | {:on_crash, (term() -> result())}

  @call_timeout 90_000

  @doc """
  A child spec identified by the memo's name, so a tree may hold several.
  """
  def child_spec(opts) do
    opts |> super() |> Map.put(:id, Keyword.fetch!(opts, :name))
  end

  @doc """
  Start a memo. `:name` names the process, its ETS table, and its child spec.

  The table is created by the process and dies with it, which is what makes
  a crashed memo a cold one rather than a stale one.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The value under `key`, loading it with `load` if nobody has a fresh one."
  @spec fetch(
          GenServer.server(),
          key(),
          (-> result()),
          (result(), integer() -> integer() | nil),
          [
            option()
          ]
        ) :: result()
  def fetch(server, key, load, expires_at, opts \\ []) when is_function(load, 0) do
    now = Keyword.get_lazy(opts, :now_ms, &now_ms/0)
    newer_than = Keyword.get(opts, :newer_than)

    case peek(server, key, now, newer_than) do
      {:ok, value} -> value
      :miss -> miss(server, key, load, expires_at, now, newer_than, opts)
    end
  end

  @doc """
  The fresh value under `key` without loading one, for a caller that can do
  without. With `newer_than`, only a value whose load started at or after
  that millisecond.
  """
  @spec peek(GenServer.server(), key(), integer(), integer() | nil) :: {:ok, result()} | :miss
  def peek(server, key, now \\ now_ms(), newer_than \\ nil) do
    hit(table(server), key, now, newer_than)
  catch
    :error, :badarg -> :miss
  end

  @doc "Forget one key. A load in flight still answers its waiters; its answer is not kept."
  @spec forget(GenServer.server(), key()) :: :ok
  def forget(server, key), do: GenServer.call(server, {:forget, [key]})

  @doc """
  Forget every key `matches?` accepts.

  Walks the keys rather than matching an ETS pattern, because the in-flight
  loads have to be walked anyway and one rule the caller can read beats two
  that have to agree.
  """
  @spec forget_where(GenServer.server(), (key() -> boolean())) :: :ok
  def forget_where(server, matches?) when is_function(matches?, 1) do
    keys =
      server
      |> table()
      |> :ets.select([{{:"$1", :_, :_, :_}, [], [:"$1"]}])
      |> Enum.filter(matches?)

    GenServer.call(server, {:forget, keys, matches?})
  end

  @doc "Forget everything. For tests, and for a caller that knows the world moved."
  @spec reset(GenServer.server()) :: :ok
  def reset(server), do: GenServer.call(server, :reset)

  defp miss(server, key, load, expires_at, now, newer_than, opts) do
    case Keyword.get(opts, :run, :task) do
      :task ->
        GenServer.call(
          server,
          {:load, key, load, expires_at, now, newer_than, on_crash(opts), Trace.memo_caller()},
          @call_timeout
        )

      :caller ->
        run_here(server, key, load, expires_at, now, newer_than, opts)
    end
  end

  # The caller runs the load itself, so the server hands out the right to do
  # so and parks everyone else. `:claimed` is not a value: it is permission,
  # stamped with the millisecond the load counts as having started -- the
  # caller's own clock, unless it was a follower handed the next load, in
  # which case the latest follower's.
  defp run_here(server, key, load, expires_at, now, newer_than, opts) do
    case GenServer.call(
           server,
           {:claim, key, now, newer_than, on_crash(opts), Trace.memo_caller()},
           @call_timeout
         ) do
      {:answered, result} ->
        result

      {:claimed, started} ->
        result =
          try do
            load.()
          catch
            kind, reason ->
              GenServer.call(server, {:abort, key, on_crash(opts).(reason)})
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        GenServer.call(server, {:done, key, result, expires_at.(result, started)})
        result
    end
  end

  defp on_crash(opts), do: Keyword.get(opts, :on_crash, &{:error, &1})

  # A memo is addressed by name, because the name is also its table and a
  # hit must not need a message to find one.
  defp table(server) when is_atom(server), do: server

  defp now_ms, do: Ravix.Clock.now_ms()

  # An entry is `{key, value, expires_at, started}`: good until `expires_at`,
  # and good *enough* for a caller that asked for `newer_than` only if its
  # load started no earlier than that.
  defp hit(table, key, now, newer_than) do
    case :ets.lookup(table, key) do
      [{^key, value, expires_at, started}]
      when expires_at > now and (is_nil(newer_than) or started >= newer_than) ->
        {:ok, value}

      _ ->
        :miss
    end
  end

  # ── the server ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :name)
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, loads: %{}}}
  end

  @impl true
  # A task runs the load. The caller waits here.
  def handle_call({:load, key, load, expires_at, now, newer_than, on_crash, trace}, from, state) do
    case hit(state.table, key, now, newer_than) do
      {:ok, value} ->
        {:reply, value, state}

      :miss ->
        caller = %{
          from: from,
          wrap: :bare,
          run: :task,
          load: load,
          expires_at: expires_at,
          now: now,
          newer_than: newer_than,
          on_crash: on_crash,
          trace: trace
        }

        {:noreply, join_or_start(state, key, [caller])}
    end
  end

  # The caller runs the load. It gets permission, or somebody else's answer.
  def handle_call({:claim, key, now, newer_than, on_crash, trace}, from, state) do
    case hit(state.table, key, now, newer_than) do
      {:ok, value} ->
        {:reply, {:answered, value}, state}

      :miss ->
        caller = %{
          from: from,
          wrap: :answered,
          run: :caller,
          load: nil,
          expires_at: nil,
          now: now,
          newer_than: newer_than,
          on_crash: on_crash,
          trace: trace
        }

        {:noreply, join_or_start(state, key, [caller])}
    end
  end

  def handle_call({:done, key, result, expires_at}, _from, state) do
    {:reply, :ok, settle(state, key, result, expires_at)}
  end

  def handle_call({:abort, key, result}, _from, state) do
    {:reply, :ok, settle(state, key, result, nil)}
  end

  def handle_call({:forget, keys}, from, state),
    do: handle_call({:forget, keys, fn _ -> false end}, from, state)

  def handle_call({:forget, keys, matches?}, _from, state) do
    Enum.each(keys, &:ets.delete(state.table, &1))

    in_flight = state.loads |> Map.keys() |> Enum.filter(&(&1 in keys or matches?.(&1)))
    {:reply, :ok, Enum.reduce(in_flight, state, &disown(&2, &1))}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, Enum.reduce(Map.keys(state.loads), state, &disown(&2, &1))}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case find_by_ref(state.loads, ref) do
      nil ->
        {:noreply, state}

      {key, load} ->
        case result do
          {:__crash__, crashed} -> {:noreply, settle(state, key, crashed, nil)}
          _ -> {:noreply, settle(state, key, result, load.expires_at.(result, load.now))}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_by_ref(state.loads, ref) do
      nil -> {:noreply, state}
      {key, load} -> {:noreply, settle(state, key, load.on_crash.(reason), nil)}
    end
  end

  # Put `callers` -- one, or the followers of a load that just settled --
  # behind `key`. A load already running takes each of them as a waiter if
  # it started late enough for them, and as a follower otherwise; with no
  # load running, one starts for all of them.
  defp join_or_start(state, key, callers) do
    case Map.fetch(state.loads, key) do
      {:ok, running} ->
        {join, follow} = Enum.split_with(callers, &joinable?(running, &1))

        put_in(
          state.loads[key],
          %{running | waiters: join ++ running.waiters, followers: running.followers ++ follow}
        )

      :error ->
        start(state, key, callers)
    end
  end

  defp joinable?(_running, %{newer_than: nil}), do: true
  defp joinable?(running, %{newer_than: newer_than}), do: running.now >= newer_than

  # One load for every caller in the list. The first of them says how it
  # runs; the load counts as started at the latest of their clocks, which is
  # the caller's own when there is one and never later than the truth.
  defp start(state, key, [lead | _] = callers) do
    started = callers |> Enum.map(& &1.now) |> Enum.max()

    {ref, waiters} =
      case lead.run do
        :task ->
          task =
            Task.Supervisor.async_nolink(Ravix.TaskSupervisor, fn ->
              lead.trace.carry.(fn -> safely(lead.load, lead.on_crash) end)
            end)

          {task.ref, callers}

        :caller ->
          {pid, _} = lead.from
          ref = Process.monitor(pid)
          GenServer.reply(lead.from, {:claimed, started})
          {ref, tl(callers)}
      end

    load = %{
      trace: Trace.memo_started(lead.trace),
      ref: ref,
      waiters: waiters,
      followers: [],
      expires_at: lead.expires_at || fn _result, _now -> nil end,
      now: started,
      on_crash: lead.on_crash
    }

    put_in(state.loads[key], load)
  end

  # Tagged, so `settle/4` can tell a result the load returned from one it
  # raised. `expires_at` is the caller's rule for good answers and is not
  # asked about crashes: a five-minute memory of "it blew up" is not a cache.
  defp safely(load, on_crash) do
    load.()
  rescue
    error -> {:__crash__, on_crash.(error)}
  end

  # Answer everybody waiting on `key`, remember the value if it may be
  # remembered, stop watching whoever produced it, and start the load the
  # followers were promised. A key that was forgotten while this ran is held
  # under `{:forgotten, ...}`: its waiters are here, and `expires_at` is nil,
  # so nothing is written.
  defp settle(state, key, result, expires_at) do
    {load, loads} = Map.pop(state.loads, key)

    if load do
      Trace.memo_shared(load.trace, Enum.map(load.waiters, & &1.trace))

      # A key held under `{:forgotten, ...}` was invalidated after this load
      # began, so its answer is already out of date. The waiters still get it,
      # because it is the best answer that exists; the table does not.
      if expires_at && not forgotten?(key),
        do: :ets.insert(state.table, {key, result, expires_at, load.now})

      Enum.each(load.waiters, fn
        %{from: from, wrap: :answered} -> GenServer.reply(from, {:answered, result})
        %{from: from, wrap: :bare} -> GenServer.reply(from, result)
      end)

      Process.demonitor(load.ref, [:flush])

      # The followers asked for something newer than this load, and it is
      # over, so theirs starts now -- under the real key, because a load that
      # begins after a forget is not the one the forget was about.
      follow_up(%{state | loads: loads}, real_key(key), load.followers)
    else
      %{state | loads: loads}
    end
  end

  defp follow_up(state, _key, []), do: state
  defp follow_up(state, key, followers), do: join_or_start(state, key, followers)

  # A forgotten load. Its waiters still deserve an answer, so the record
  # moves to a key no reader asks for and stays there until it reports.
  defp disown(state, key) do
    case Map.pop(state.loads, key) do
      {nil, _} -> state
      {load, loads} -> %{state | loads: Map.put(loads, {:forgotten, key, load.ref}, load)}
    end
  end

  defp find_by_ref(loads, ref), do: Enum.find(loads, fn {_key, load} -> load.ref == ref end)

  defp forgotten?({:forgotten, _key, _ref}), do: true
  defp forgotten?(_key), do: false

  defp real_key({:forgotten, key, _ref}), do: key
  defp real_key(key), do: key
end

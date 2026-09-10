defmodule Ravix.GitHub.Cache do
  @moduledoc """
  What the GitHub client remembers between calls.

  Three things, all keyed by the App id so two configured Apps never share:

    * **Installation tokens**, cached until a minute before they expire. A
      minute of slack rather than none because the token is handed to a
      machine that then uses it: a token that was valid when it left here and
      expired in flight fails as `fatal: Authentication failed`, which reads
      like a permissions problem and is not one.
    * **Rate limits**, per installation. Once GitHub says stop, every read for
      that installation is refused locally until the reset, so twenty mounted
      rows do not each discover the limit for themselves.
    * **Checks reports**, for five minutes, including the in-flight read.
      Rows, tabs and viewers asking about the same branch share one request;
      a failed read is remembered for a minute (or until the rate limit
      lifts) so a failure does not turn every mounted row into a retry loop.

  Tokens and rate limits live in a public ETS table and are read and written
  by the caller. Checks go through the server, which is the only place that
  can hand one caller the read and park the others until it lands.

  Started by `Ravix.Application`. If it is not running when first used (a
  test run before it was wired in) the first caller starts it unsupervised,
  so the table outlives any single test process.
  """

  use GenServer

  alias Ravix.GitHub.{Clock, Error}

  @table :ravix_github_cache

  @type app_id :: String.t()
  @type installation_id :: integer()
  @type checks_key :: tuple()
  @type checks_result :: {:ok, term()} | {:error, Error.t()}

  # ── lifecycle ──────────────────────────────────────────────────────

  @doc "Start under a supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── installation tokens ────────────────────────────────────────────

  @doc "The cached token for an installation and when it expires, if any."
  @spec token(app_id(), installation_id()) :: {:ok, String.t(), integer()} | :error
  def token(app_id, installation_id) do
    ensure()

    case :ets.lookup(@table, {:token, app_id, installation_id}) do
      [{_, token, expires_at_ms}] -> {:ok, token, expires_at_ms}
      [] -> :error
    end
  end

  @doc "Remember a freshly minted token."
  @spec put_token(app_id(), installation_id(), String.t(), integer()) :: :ok
  def put_token(app_id, installation_id, token, expires_at_ms) do
    ensure()
    :ets.insert(@table, {{:token, app_id, installation_id}, token, expires_at_ms})
    :ok
  end

  # ── rate limits ────────────────────────────────────────────────────

  @doc "The rate limit GitHub imposed on an installation, if one is remembered."
  @spec rate_limit(app_id(), installation_id()) :: {:ok, integer(), Error.t()} | :error
  def rate_limit(app_id, installation_id) do
    ensure()

    case :ets.lookup(@table, {:rate_limit, app_id, installation_id}) do
      [{_, until_ms, error}] -> {:ok, until_ms, error}
      [] -> :error
    end
  end

  @doc "Refuse reads for this installation until `until_ms`, answering `error`."
  @spec put_rate_limit(app_id(), installation_id(), integer(), Error.t()) :: :ok
  def put_rate_limit(app_id, installation_id, until_ms, %Error{} = error) do
    ensure()
    :ets.insert(@table, {{:rate_limit, app_id, installation_id}, until_ms, error})
    :ok
  end

  @doc "Forget a rate limit (it expired, or a request got through)."
  @spec clear_rate_limit(app_id(), installation_id()) :: :ok
  def clear_rate_limit(app_id, installation_id) do
    ensure()
    :ets.delete(@table, {:rate_limit, app_id, installation_id})
    :ok
  end

  # ── checks ─────────────────────────────────────────────────────────

  @doc """
  The checks report under `key`, reading it with `fun` if nobody has.

  `fun` runs in the calling process (so it sees the caller's `Req.Test`
  stubs); other callers arriving while it runs wait for its answer. `now_ms`
  is the caller's clock, so the tests can move it.
  """
  @spec checks(app_id(), checks_key(), integer(), (-> checks_result())) :: checks_result()
  def checks(app_id, key, now_ms, fun) when is_function(fun, 0) do
    ensure()
    full_key = {app_id, key}

    case GenServer.call(__MODULE__, {:checks_claim, full_key, now_ms}, :infinity) do
      {:hit, result} ->
        result

      {:wait, result} ->
        result

      :run ->
        result =
          try do
            fun.()
          catch
            kind, reason ->
              GenServer.call(__MODULE__, {:checks_abort, full_key})
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        GenServer.call(__MODULE__, {:checks_done, full_key, result, expires_at(result)})
        result
    end
  end

  @doc "Drop every checks report whose key `matches?` (a pull request was opened)."
  @spec drop_checks(app_id(), (checks_key() -> boolean())) :: :ok
  def drop_checks(app_id, matches?) when is_function(matches?, 1) do
    ensure()
    GenServer.call(__MODULE__, {:checks_drop, app_id, matches?})
  end

  # A report is good for five minutes. A failure is remembered for a minute,
  # or until the rate limit that caused it lifts, whichever is later.
  defp expires_at({:ok, _}), do: Clock.now_ms() + 5 * 60_000

  defp expires_at({:error, error}) do
    retry_at =
      case error do
        %Error{retry_at_ms: ms} when is_integer(ms) -> ms
        _ -> 0
      end

    max(Clock.now_ms() + 60_000, retry_at)
  end

  # ── server ─────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{waiters: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:checks_claim, key, now_ms}, {pid, _} = from, state) do
    case :ets.lookup(@table, {:checks, key}) do
      [{_, :ready, result, expires_at}] when expires_at > now_ms ->
        {:reply, {:hit, result}, state}

      [{_, :inflight, _runner}] ->
        {:noreply, update_in(state.waiters[key], &[from | &1 || []])}

      _ ->
        sweep(now_ms)
        ref = Process.monitor(pid)
        :ets.insert(@table, {{:checks, key}, :inflight, pid})
        {:reply, :run, put_in(state.monitors[ref], key)}
    end
  end

  def handle_call({:checks_done, key, result, expires_at}, {pid, _}, state) do
    case :ets.lookup(@table, {:checks, key}) do
      # Still the read this key is waiting on, so its answer is current.
      [{_, :inflight, ^pid}] ->
        :ets.insert(@table, {{:checks, key}, :ready, result, expires_at})
        {:reply, :ok, settle(state, key, {:wait, result})}

      # Dropped while this read was in flight: it was started before whatever
      # invalidated the key -- opening the pull request, most often -- so its
      # answer is already out of date. Everyone waiting on it still gets it,
      # because it is the best answer that exists right now, but it must not
      # be cached: a five-minute stale report is how "no pull request" outlives
      # the pull request.
      _ ->
        {:reply, :ok, settle(state, key, {:wait, result})}
    end
  end

  def handle_call({:checks_abort, key}, _from, state) do
    :ets.delete(@table, {:checks, key})
    {:reply, :ok, settle(state, key, {:wait, {:error, crashed()}})}
  end

  def handle_call({:checks_drop, app_id, matches?}, _from, state) do
    # Both shapes: a cached report, and a read that is still running. Dropping
    # the in-flight entry is what takes away its right to cache what it
    # returns; it still answers everyone already waiting on it.
    ready = :ets.match(@table, {{:checks, {app_id, :"$1"}}, :ready, :_, :_})
    inflight = :ets.match(@table, {{:checks, {app_id, :"$1"}}, :inflight, :_})

    for [key] <- ready ++ inflight,
        matches?.(key),
        do: :ets.delete(@table, {:checks, {app_id, key}})

    {:reply, :ok, state}
  end

  def handle_call(:ping, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {key, monitors} ->
        state = %{state | monitors: monitors}

        case :ets.lookup(@table, {:checks, key}) do
          [{_, :inflight, _}] ->
            :ets.delete(@table, {:checks, key})
            {:noreply, settle(state, key, {:wait, {:error, crashed()}})}

          _ ->
            {:noreply, state}
        end
    end
  end

  # Answer everyone parked on `key` and stop watching its runner.
  defp settle(state, key, reply) do
    {waiters, remaining} = Map.pop(state.waiters, key, [])
    Enum.each(waiters, &GenServer.reply(&1, reply))

    monitors =
      state.monitors
      |> Enum.reject(fn {ref, k} ->
        if k == key, do: Process.demonitor(ref, [:flush])
        k == key
      end)
      |> Map.new()

    %{state | waiters: remaining, monitors: monitors}
  end

  # Share both the report and in-flight work across rows, tabs and viewers,
  # but do not keep stale ones around forever.
  defp sweep(now_ms) do
    :ets.select_delete(@table, [
      {{{:checks, :_}, :ready, :_, :"$1"}, [{:"=<", :"$1", now_ms}], [true]}
    ])
  end

  defp crashed, do: %Error{status: nil, message: "The checks read did not complete."}

  # The application supervisor starts this; a bare test run gets it on first use.
  defp ensure do
    if :ets.whereis(@table) == :undefined do
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> GenServer.call(__MODULE__, :ping)
      end
    end

    :ok
  end
end

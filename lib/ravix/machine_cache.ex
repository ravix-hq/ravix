defmodule Ravix.MachineCache do
  @moduledoc """
  One Fountain call per burst, not one per request.

  A project's machine is derived from its conversations rather than stored
  (see `Ravix.Tracks.machine_of/2` for why), and the derivation used to run
  on every request that needed it: the file, diff and listing routes, the
  terminal, the vitals readout every twenty seconds per viewer, the preview
  reconciler every fifteen. Each one listed the agent's conversations afresh.
  Across the deployed apps that was part of ~50,000 conversation-list calls
  an hour against production and a four-day database-pool incident
  (2026-09-07).

  So the list is memoised, briefly, per Fountain client and project:

    - **Short.** `ttl_ms/0` is a few seconds: enough that one screen's burst
      of requests costs one call, short enough that nothing on screen is
      stale for long.
    - **Coalesced.** Concurrent misses share one in-flight load.
    - **Invalidated on the writes that change the answer.** Opening a track
      (which may provision the machine), closing one, rebuilding or
      destroying the project: each calls `forget_project/1`.
    - **Refreshed by whoever needs it fresh.** The sidebar's status dot must
      not lag a turn ending, so `Ravix.Tracks.list/2` and `get/2` read live
      and write the result through; everything that only needs the machine's
      identity reads from the memo.

  The sprite behind a sandbox never changes for a given sandbox id, so that
  lookup is memoised for longer; a "not a sprite" answer only briefly, since
  a sandbox mid-provisioning may not have one yet.

  Values live in a public ETS table so a hit never touches the server; only
  misses go through the GenServer, which is where concurrent misses are
  joined onto one load. The load itself runs in a task under
  `Ravix.TaskSupervisor` so a slow Fountain blocks the waiters and nobody
  else. An entry is keyed on the client's base URL as well as the project:
  tests build a client per case, and a memo keyed on the project alone would
  hand one test another's answer. In production there is one client.
  """

  use GenServer

  alias Ravix.Fountain
  alias Ravix.Fountain.Client

  @table __MODULE__
  @ttl_ms 5_000
  @sprite_ttl_ms 60_000
  @load_timeout 90_000
  @live_statuses ~w(pending idle running)

  @typedoc "A conversation as `GET /api/conversations` lists it (string keys)."
  @type conversation :: %{optional(String.t()) => term()}
  @typedoc "Which machine a project is on, or nil when no live conversation names one."
  @type machine :: %{sandbox_id: String.t()} | nil
  @type project :: %{:id => String.t(), :agent_id => String.t(), optional(atom()) => term()}
  @type opts :: [fresh: boolean(), now_ms: integer()]

  @doc "How long a conversation list stands before it is re-read."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc "How long a sandbox's sprite name stands. It does not change."
  @spec sprite_ttl_ms() :: pos_integer()
  def sprite_ttl_ms, do: @sprite_ttl_ms

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The project's agent's conversations: from the memo while fresh, unless
  `fresh: true`, in which case Fountain is asked and the memo refreshed.
  Narrowed to the project's agent, never the whole account. A failed read is
  nobody's answer: the next caller retries.
  """
  @spec conversations(Client.t(), project(), opts()) ::
          {:ok, [conversation()]} | {:error, Fountain.failure()}
  def conversations(%Client{} = client, project, opts \\ []) do
    key = list_key(client, project)
    if opts[:fresh], do: forget(key)

    memo(
      key,
      fn -> Fountain.list_conversations(client, project.agent_id) end,
      fn _ -> @ttl_ms end,
      opts
    )
  end

  @doc """
  The project's machine, read from its conversations. Nothing is stored.

  The list is enough for everything except the terminal: it carries
  `sandbox_id`, which is all the file, diff and listing routes need. It does
  *not* carry the sandbox object (`GET /api/conversations` serves
  `"sandbox": null`), so anything wanting `sprite_name` has to ask
  `sprite_for/3` and pay for the extra call.

  The newest live conversation with a sandbox wins. `fresh: true` is for the
  guards whose whole job is to notice the machine was replaced under them
  (the preview reconciler and the agent helper) and asks Fountain every time.
  """
  @spec machine_of(Client.t(), project(), opts()) ::
          {:ok, machine()} | {:error, Fountain.failure()}
  def machine_of(%Client{} = client, project, opts \\ []) do
    with {:ok, all} <- conversations(client, project, opts) do
      newest =
        all
        |> Enum.filter(&(is_binary(&1["sandbox_id"]) and &1["status"] in @live_statuses))
        |> Enum.sort_by(&to_string(&1["inserted_at"]), :desc)
        |> List.first()

      {:ok, if(newest, do: %{sandbox_id: newest["sandbox_id"]})}
    end
  end

  @doc """
  The sprite behind a sandbox, or nil if it is not on Sprites at all.

  Made only by the panels that need a shell, and memoised per sandbox for a
  minute: a sandbox id names one machine, and its sprite does not change. A
  sandbox on another provider is a real answer rather than a failure (the
  terminal says so), which is why this is nil instead of an error, and why a
  Fountain failure reads as nil too.
  """
  @spec sprite_for(Client.t(), String.t(), opts()) :: String.t() | nil
  def sprite_for(%Client{} = client, sandbox_id, opts \\ []) do
    sprite_name(
      client,
      sandbox_id,
      fn ->
        case Fountain.sandbox(client, sandbox_id) do
          {:ok, %{"sprite_name" => name}} when is_binary(name) and name != "" -> name
          _ -> nil
        end
      end,
      opts
    )
  end

  @doc "The sprite behind one sandbox, through `load`, memoised. Nil when it is not on Sprites."
  @spec sprite_name(Client.t(), String.t(), (-> String.t() | nil), opts()) :: String.t() | nil
  def sprite_name(%Client{} = client, sandbox_id, load, opts \\ []) when is_function(load, 0) do
    key = {client_id(client), :sprite, sandbox_id}

    case memo(key, fn -> {:ok, load.()} end, &if(&1, do: @sprite_ttl_ms, else: @ttl_ms), opts) do
      {:ok, name} -> name
      _ -> nil
    end
  end

  @doc "Forget what was derived for one project, on every client."
  @spec forget_project(String.t()) :: :ok
  def forget_project(project_id) do
    GenServer.call(server(), {:forget_project, project_id})
  end

  @doc "For tests: forget everything."
  @spec reset() :: :ok
  def reset, do: GenServer.call(server(), :reset)

  # ── the memo ──────────────────────────────────────────────────────────

  defp memo(key, load, ttl_for, opts) do
    now = Keyword.get_lazy(opts, :now_ms, &now_ms/0)

    case :ets.lookup(table(), key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      _ ->
        GenServer.call(server(), {:load, key, load, ttl_for, now}, @load_timeout)
    end
  end

  defp forget(key), do: GenServer.call(server(), {:forget, key})

  defp list_key(client, project),
    do: {client_id(client), :conversations, project.id, project.agent_id}

  defp client_id(%Client{base_url: base_url}), do: base_url

  defp now_ms, do: System.system_time(:millisecond)

  defp server, do: __MODULE__
  defp table, do: @table

  # ── the server: coalescing loads, one task each ───────────────────────

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, loads: %{}}}
  end

  @impl true
  def handle_call({:load, key, load, ttl_for, now}, from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:reply, {:ok, value}, state}

      _ ->
        {:noreply, start_or_join(state, key, load, ttl_for, now, from)}
    end
  end

  def handle_call({:forget, key}, _from, state) do
    :ets.delete(state.table, key)
    # A load in flight answers its waiters but is not remembered.
    {:reply, :ok, %{state | loads: drop_load(state.loads, key)}}
  end

  def handle_call({:forget_project, project_id}, _from, state) do
    :ets.match_delete(state.table, {{:_, :conversations, project_id, :_}, :_, :_})

    loads =
      state.loads
      |> Map.keys()
      |> Enum.filter(&match?({_, :conversations, ^project_id, _}, &1))
      |> Enum.reduce(state.loads, &drop_load(&2, &1))

    {:reply, :ok, %{state | loads: loads}}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | loads: %{}}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Enum.find(state.loads, fn {_key, load} -> load.ref == ref end) do
      nil ->
        # Forgotten while in flight. Its waiters were answered by the load
        # that replaced it, or are answered here when there was none.
        {:noreply, state}

      {key, load} ->
        settle(state.table, key, load, result)
        {:noreply, %{state | loads: Map.delete(state.loads, key)}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.loads, fn {_key, load} -> load.ref == ref end) do
      nil ->
        {:noreply, state}

      {key, load} ->
        error =
          {:error,
           %Ravix.Fountain.Error{
             status: 0,
             code: "load_crashed",
             message: inspect(reason),
             kind: :connection
           }}

        Enum.each(load.waiters, &GenServer.reply(&1, error))
        {:noreply, %{state | loads: Map.delete(state.loads, key)}}
    end
  end

  defp start_or_join(state, key, load, ttl_for, now, from) do
    case Map.fetch(state.loads, key) do
      {:ok, running} ->
        put_in(state.loads[key], %{running | waiters: [from | running.waiters]})

      :error ->
        task = Task.Supervisor.async_nolink(Ravix.TaskSupervisor, fn -> safe_load(load) end)
        put_in(state.loads[key], %{ref: task.ref, waiters: [from], ttl_for: ttl_for, now: now})
    end
  end

  defp safe_load(load) do
    load.()
  rescue
    error ->
      {:error,
       %Ravix.Fountain.Error{
         status: 0,
         code: "load_raised",
         message: Exception.message(error),
         kind: :connection
       }}
  end

  defp settle(table, key, load, {:ok, value} = result) do
    # Held from the moment the load started, as the TypeScript did, so the
    # value's own TTL is not stretched by however long Fountain took. A load
    # forgotten while in flight answers its waiters but is not remembered.
    unless match?({:forgotten, _, _}, key),
      do: :ets.insert(table, {key, value, load.now + load.ttl_for.(value)})

    Enum.each(load.waiters, &GenServer.reply(&1, result))
  end

  defp settle(_table, _key, load, result) do
    Enum.each(load.waiters, &GenServer.reply(&1, result))
  end

  # A forgotten load: its waiters still deserve an answer, so the record is
  # kept under a key no reader asks for until the task reports.
  defp drop_load(loads, key) do
    case Map.pop(loads, key) do
      {nil, loads} -> loads
      {load, loads} -> Map.put(loads, {:forgotten, key, load.ref}, load)
    end
  end
end

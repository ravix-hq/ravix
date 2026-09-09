defmodule Ravix.Tracks.Follower do
  @moduledoc """
  Fountain's stream for one track, followed once and fanned out.

  The TypeScript forwarded Fountain's server-sent stream to each browser,
  one upstream connection per open tab. Here a track has at most one
  follower, a process that keeps `Ravix.Fountain.each_event/4` running on the
  conversation while anybody is subscribed and broadcasts every event as
  `{:transcript, track_id, event}` on the PubSub topic `track:<id>`. Three
  people reading one track cost one upstream connection, and a LiveView
  that dies is one subscriber fewer rather than one connection to cancel.

  A follower lives exactly as long as it is wanted. `subscribe/2` starts it
  if it is not running and registers the caller; the caller is monitored,
  and a few seconds after the last subscriber leaves (a grace period, so a
  page that reconnects does not pay for a fresh stream) the follower stops.
  A stream that ends or fails is reopened after a short wait from the last
  event id seen, as the browser's `EventSource` reconnected with
  `Last-Event-ID`, for as long as anybody is still listening.

  **Access is the subscriber's job.** `stream-access.ts` kept a revocation
  check alive beside every forwarded stream so a removed member stopped
  receiving on the next event. Here the follower does not know who is
  listening; a page subscribed to a track re-checks
  `Ravix.Accounts.Access.track_access/2` when the project's hub says its
  people or tracks changed, and unsubscribes if it is no longer allowed. It
  therefore stops receiving on the event after the revocation, which is the
  same guarantee.

  Registered in `Ravix.Tracks.Follower.Registry` and started under
  `Ravix.Tracks.Follower.Supervisor`, both of which the application starts.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Ravix.Fountain
  alias Ravix.Fountain.Client
  alias Ravix.Repo
  alias Ravix.Tracks.Track

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor
  @linger_ms 3_000
  @retry_ms 1_000
  @retry_max_ms 15_000

  @typedoc "Options for `subscribe/2`; a test passes the conversation and client rather than reading a row."
  @type option ::
          {:conversation_id, String.t()}
          | {:client, Client.t()}
          | {:after, integer() | nil}
          | {:stream_opts, keyword()}
          | {:linger_ms, pos_integer()}
          | {:retry_ms, pos_integer()}

  @doc "The PubSub topic a track's events are broadcast on."
  @spec topic(String.t()) :: String.t()
  def topic(track_id), do: "track:" <> track_id

  @doc "The registry the application starts for followers."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The dynamic supervisor the application starts for followers."
  @spec supervisor() :: atom()
  def supervisor, do: @supervisor

  @doc """
  Receive `{:transcript, track_id, event}` in the calling process while the
  track's conversation is followed.

  The track's conversation is read from its row unless `:conversation_id` is
  given; `{:error, :not_open}` when it has none. `:after` is the newest event
  id the caller already holds, so a page that loaded the transcript first
  does not have the follower replay it (a follower already running keeps its
  own cursor). `:client`, `:stream_opts`, `:linger_ms` and `:retry_ms` exist
  for tests and only matter to the follower this call starts.
  """
  @spec subscribe(String.t(), [option()]) :: :ok | {:error, :not_open | term()}
  def subscribe(track_id, opts \\ []) do
    with {:ok, conversation_id} <- conversation_id(track_id, opts),
         {:ok, pid} <- ensure_started(track_id, conversation_id, opts) do
      :ok = Phoenix.PubSub.subscribe(Ravix.PubSub, topic(track_id))
      GenServer.call(pid, {:subscribe, self()})
    end
  end

  @doc "Stop receiving a track's events. The follower stops shortly after its last subscriber leaves."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(track_id) do
    Phoenix.PubSub.unsubscribe(Ravix.PubSub, topic(track_id))

    case whereis(track_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:unsubscribe, self()})
    end
  end

  @doc "The follower for a track, if one is running."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(track_id) do
    case Registry.lookup(@registry, track_id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end

  @doc false
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, args.track_id}})
  end

  defp conversation_id(track_id, opts) do
    case Keyword.get(opts, :conversation_id) do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        case Repo.get(Track, track_id) do
          %Track{conversation_id: id} when is_binary(id) and id != "" -> {:ok, id}
          _ -> {:error, :not_open}
        end
    end
  end

  defp ensure_started(track_id, conversation_id, opts) do
    args = %{
      track_id: track_id,
      conversation_id: conversation_id,
      client: Keyword.get_lazy(opts, :client, &Fountain.client/0),
      after: Keyword.get(opts, :after),
      stream_opts: Keyword.get(opts, :stream_opts, []),
      linger_ms: Keyword.get(opts, :linger_ms),
      retry_ms: Keyword.get(opts, :retry_ms)
    }

    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, args}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── the process ───────────────────────────────────────────────────────

  @impl true
  def init(args) do
    config = Application.get_env(:ravix, __MODULE__, [])

    state = %{
      track_id: args.track_id,
      conversation_id: args.conversation_id,
      client: args.client,
      last_id: args.after || 0,
      stream_opts: Keyword.merge(Keyword.get(config, :stream_opts, []), args.stream_opts),
      linger_ms: args.linger_ms || Keyword.get(config, :linger_ms, @linger_ms),
      retry_ms: args.retry_ms || Keyword.get(config, :retry_ms, @retry_ms),
      subscribers: %{},
      task: nil,
      attempt: 0,
      stop_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state = state |> cancel_stop() |> open_stream()

    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state), do: {:noreply, drop_subscriber(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscribers: subs} = state)
      when is_map_key(subs, pid) do
    {:noreply, drop_subscriber(state, pid)}
  end

  # The stream task reported: it ended cleanly, or Fountain refused it, or the
  # connection could not be kept. Either way, reopen from the last id while
  # somebody is listening.
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, reopen_later(%{state | task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, reopen_later(%{state | task: nil}, {:error, reason})}
  end

  def handle_info({:seen, id}, state) when is_integer(id) do
    {:noreply, %{state | last_id: max(state.last_id, id), attempt: 0}}
  end

  def handle_info(:reopen, state), do: {:noreply, open_stream(state)}

  def handle_info(:stop, %{subscribers: subs} = state) when map_size(subs) == 0,
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_reason, _state), do: :ok

  # ── streaming ─────────────────────────────────────────────────────────

  defp open_stream(%{task: %Task{}} = state), do: state

  defp open_stream(state) do
    follower = self()
    %{track_id: track_id, conversation_id: conversation_id, client: client} = state
    opts = Keyword.put(state.stream_opts, :after, state.last_id)

    task =
      Task.Supervisor.async_nolink(Ravix.TaskSupervisor, fn ->
        Fountain.each_event(client, conversation_id, &relay(&1, track_id, follower), opts)
      end)

    %{state | task: task}
  end

  # Runs in the stream task: every event to the topic, its id to the follower.
  defp relay(event, track_id, follower) do
    Phoenix.PubSub.broadcast(Ravix.PubSub, topic(track_id), {:transcript, track_id, event})
    if is_integer(event["id"]), do: send(follower, {:seen, event["id"]})
    :cont
  end

  defp reopen_later(state, result) do
    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info("ravix: transcript for track #{state.track_id} dropped: #{inspect(reason)}")
    end

    # Backed off, doubling up to a ceiling, and reset by any event arriving.
    delay = min(state.retry_ms * Integer.pow(2, min(state.attempt, 14)), @retry_max_ms)
    Process.send_after(self(), :reopen, delay)
    %{state | attempt: state.attempt + 1}
  end

  # ── subscribers ───────────────────────────────────────────────────────

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        state

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        state = %{state | subscribers: subscribers}
        if subscribers == %{}, do: schedule_stop(state), else: state
    end
  end

  defp schedule_stop(%{stop_timer: nil} = state),
    do: %{state | stop_timer: Process.send_after(self(), :stop, state.linger_ms)}

  defp schedule_stop(state), do: state

  defp cancel_stop(%{stop_timer: nil} = state), do: state

  defp cancel_stop(%{stop_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | stop_timer: nil}
  end
end

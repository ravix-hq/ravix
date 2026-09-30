defmodule Ravix.Terminal.Shell do
  @moduledoc """
  One open terminal tab: the socket to its shell, held for one page.

  Started by `Ravix.Terminal.attach/5`, which has established track access
  and found the tab, the sprite and the Sprites token first. The page that
  asked is the owner, and gets, as messages:

    * `{:terminal, tab_id, :ready}` --- the shell is attached; what follows
      replaces whatever the page was showing for this tab
    * `{:terminal, tab_id, {:data, bytes}}` --- output, coalesced
    * `{:terminal, tab_id, {:exited, code}}` --- the shell ended; the tab is gone
    * `{:terminal, tab_id, {:ended, reason}}` --- the tab is gone for another
      reason: `:revoked` (the session or the person's access ended), `:lost`
      (Sprites no longer has the shell), or a `Ravix.Sprites.Error`
    * `{:terminal, tab_id, :disconnected}` --- the socket dropped but the
      shell may still be running; attaching again resumes it

  ## Access is watched here, not only on the page

  Mount-time checks are not enough, and neither is the page's own guard:
  the page hears about a revoked session or a removed member only when a
  message reaches it, and an idle terminal sends none. So this process
  answers the question itself, on the same three signals
  `RavixWeb.Live.Guard` documents --- the session's own expiry (a timer),
  `{:session_ended, hash}` on the session's topic, and `:people` or
  `:tracks` on the project's hub --- plus the same fifteen-second backstop
  for a notice lost on a partition. When the answer is no, the shell is
  *killed*, not merely let go, its row is deleted, and the page is told.

  ## Why this is not a `:global` name (ADR 0003)

  A second instance may run its own, and must be allowed to. What must be
  unique is the shell, and it is: it lives on the sprite, named by the
  Sprites session id in `terminal_tabs`, and outlives this process. This is
  only one page's attachment to it. When the page goes --- a reconnect, a
  deploy, the instance leaving --- this process detaches and stops; the
  page's next mount, wherever it lands, starts a fresh one that re-attaches
  and gets the scrollback replayed. Two attachments at once (the same person
  in two browser tabs) are two views of one shell, which is what a terminal
  multiplexer does anyway. A `:global` name would instead make the second
  browser tab steal the first one's terminal, and would add a cluster-wide
  registration to every keystroke's path for nothing.

  So it is supervised node-locally under `Ravix.Terminal.Supervisor`,
  `:temporary` (a crashed attachment is re-made by the page, not by the
  supervisor, which would not know whether access still stands), and it
  monitors its owner and stops with it. It is registered in the node-local
  `Ravix.Terminal.Registry` under `{owner, tab_id}`, which is how the page
  reaches it (`input/3`) without holding a pid, and why no other process
  can type into it: the key starts with the caller's own pid.

  ## Backpressure

  Output is coalesced for a frame (`@flush_ms`) before it goes to the page,
  so `yes` is a few messages a second and not a message per packet. While
  the page's mailbox is behind, the socket is not re-armed, which stalls the
  shell on the sprite rather than filling memory here --- the same rule as
  `Ravix.Sprites.Tunnel`.
  """

  use GenServer, restart: :temporary

  alias Ravix.Accounts
  alias Ravix.Accounts.Access
  alias Ravix.Accounts.User
  alias Ravix.Hub
  alias Ravix.Hub.Event
  alias Ravix.Sprites.Pty
  alias Ravix.Terminal.Store
  alias Ravix.Terminal.Tab

  @flush_ms 16
  @max_chunk 64 * 1024
  @max_owner_queue 256
  @resume_ms 10
  @recheck_ms 15_000

  @typedoc "What `start_link/1` needs: all of it established by `Ravix.Terminal`."
  @type opts :: %{
          required(:cfg) => Ravix.Config.Sprites.t(),
          required(:tab) => Tab.t(),
          required(:user) => User.t(),
          required(:project_id) => String.t(),
          required(:session_hash) => String.t(),
          required(:expires_at) => DateTime.t(),
          required(:owner) => pid(),
          required(:dir) => String.t(),
          required(:cols) => pos_integer(),
          required(:rows) => pos_integer(),
          optional(:callers) => [pid()]
        }

  @doc false
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: name(opts.owner, opts.tab.id))

  @doc "The shell `owner` has attached to `tab_id`, if any."
  @spec whereis(pid(), String.t()) :: pid() | nil
  def whereis(owner, tab_id) do
    case Registry.lookup(Ravix.Terminal.Registry, {owner, tab_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp name(owner, tab_id), do: {:via, Registry, {Ravix.Terminal.Registry, {owner, tab_id}}}

  @doc "Bytes typed into the calling page's terminal `tab_id`."
  @spec input(pid(), String.t(), binary()) :: :ok
  def input(owner, tab_id, data), do: GenServer.cast(name(owner, tab_id), {:input, data})

  @doc "The new size of the calling page's terminal `tab_id`."
  @spec resize(pid(), String.t(), pos_integer(), pos_integer()) :: :ok
  def resize(owner, tab_id, cols, rows),
    do: GenServer.cast(name(owner, tab_id), {:resize, cols, rows})

  @doc "Let go of the shell without ending it. Idempotent."
  @spec detach(pid(), String.t()) :: :ok
  def detach(owner, tab_id) do
    GenServer.stop(name(owner, tab_id), :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  # ── start ────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # The page's callers, as a `Task` would carry them, so the database
    # sandbox and the provider stubs in a test follow the page here.
    Process.put(:"$callers", Map.get(opts, :callers, [opts.owner]))
    owner_ref = Process.monitor(opts.owner)
    Hub.subscribe(opts.project_id)
    Accounts.subscribe_session(opts.session_hash)

    state =
      opts
      |> Map.take([:cfg, :tab, :user, :project_id, :session_hash, :owner, :dir, :cols, :rows])
      |> Map.merge(%{
        owner_ref: owner_ref,
        pty: nil,
        out: [],
        out_size: 0,
        flush: nil,
        paused?: false,
        expiry: nil
      })
      |> schedule_expiry(opts.expires_at)

    Process.send_after(self(), :recheck, @recheck_ms)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    %{cfg: cfg, tab: tab} = state

    target =
      case tab.session_id do
        nil ->
          {:spawn,
           %{
             argv: ["bash", "-l"],
             dir: state.dir,
             env: [{"TERM", "xterm-256color"}, {"COLORTERM", "truecolor"}],
             cols: state.cols,
             rows: state.rows
           }}

        session_id ->
          {:attach, session_id}
      end

    case Pty.open(cfg, tab.sprite, target) do
      {:ok, pty, events} ->
        notify(state, :ready)
        state = %{state | pty: pty}

        # An attach replays at the size the shell last had; tell it this
        # page's size, which is what the replay should be drawn at.
        state = if tab.session_id, do: resize_pty(state, state.cols, state.rows), else: state
        events(events, state)

      {:error, %{status: 404}} when tab.session_id != nil ->
        # The shell ended while nobody was attached: it exited, or
        # `max_run_after_disconnect` ran out, or the machine was rebuilt.
        forget(state)
        {:stop, :normal, ended(state, :lost)}

      {:error, _unreachable} when tab.session_id != nil ->
        # The shell may well still be running; the tab keeps its session for
        # the next attempt.
        {:stop, :normal, disconnected(state)}

      {:error, error} ->
        forget(state)
        {:stop, :normal, ended(state, error)}
    end
  end

  # ── from the page ────────────────────────────────────────────────────

  # `handle_continue/2` either attached the shell or stopped, so there is
  # always a socket by the time anything from the page is handled.
  @impl true
  def handle_cast({:input, data}, state) do
    case Pty.input(state.pty, data) do
      {:ok, pty} -> {:noreply, %{state | pty: pty}}
      {:error, _reason} -> {:stop, :normal, disconnected(state)}
    end
  end

  def handle_cast({:resize, cols, rows}, state),
    do: {:noreply, resize_pty(state, cols, rows)}

  # ── from the socket, the clock, and the news ─────────────────────────

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush: nil})}

  def handle_info(:resume, state), do: {:noreply, resume(%{state | paused?: false})}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    # The page went: a reconnect, a navigation, a closed browser tab. The
    # shell stays for the next page to re-attach to.
    {:stop, :normal, %{state | owner: nil}}
  end

  def handle_info({:session_ended, hash}, %{session_hash: hash} = state),
    do: revoke(state)

  def handle_info(:expired, state), do: recheck(state)

  def handle_info(:recheck, state) do
    Process.send_after(self(), :recheck, @recheck_ms)
    recheck(state)
  end

  def handle_info({:hub, %Event{name: name} = event}, state) when name in [:people, :tracks] do
    if Event.concerns?(event, state.tab.track_id), do: recheck(state), else: {:noreply, state}
  end

  def handle_info(message, state) do
    case Pty.handle(state.pty, message) do
      {:ok, pty, events} -> events(events, %{state | pty: pty})
      {:error, _reason} -> {:stop, :normal, disconnected(state)}
      :unknown -> {:noreply, state}
    end
  end

  # A crash report prints the state. The Sprites config already redacts its
  # token from `Inspect`, but the session hash and whatever the terminal was
  # in the middle of printing have no business in a log either.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{} = state -> Map.drop(state, [:cfg, :session_hash, :out])
      other -> other
    end)
  end

  @impl true
  def terminate(_reason, state) do
    if state.pty, do: Pty.detach(state.pty)
    :ok
  end

  # ── events ───────────────────────────────────────────────────────────

  defp events([], state), do: {:noreply, resume(state)}

  defp events([{:data, data} | rest], state), do: events(rest, buffer(state, data))

  defp events([{:session, id} | rest], state) do
    if state.tab.session_id != id, do: Store.put_session(state.tab.id, state.user.id, id)
    events(rest, %{state | tab: %{state.tab | session_id: id}})
  end

  defp events([{:exit, code} | _rest], state) do
    state = flush(state)
    forget(state)
    notify(state, {:exited, code})
    {:stop, :normal, %{state | owner: nil}}
  end

  defp events([:closed | _rest], state), do: {:stop, :normal, disconnected(flush(state))}

  defp buffer(state, data) do
    state = %{state | out: [state.out, data], out_size: state.out_size + byte_size(data)}

    cond do
      state.out_size >= @max_chunk -> flush(state)
      state.flush -> state
      true -> %{state | flush: Process.send_after(self(), :flush, @flush_ms)}
    end
  end

  defp flush(%{out_size: 0} = state), do: state

  defp flush(state) do
    if state.flush, do: Process.cancel_timer(state.flush)
    notify(state, {:data, IO.iodata_to_binary(state.out)})
    %{state | out: [], out_size: 0, flush: nil}
  end

  # Re-arm the socket for one more packet unless the page is behind, in
  # which case look again shortly: the pause is the backpressure.
  defp resume(%{paused?: true} = state), do: state

  defp resume(state) do
    case Process.info(state.owner, :message_queue_len) do
      {:message_queue_len, queued} when queued < @max_owner_queue ->
        Pty.arm(state.pty)
        state

      _behind ->
        Process.send_after(self(), :resume, @resume_ms)
        %{state | paused?: true}
    end
  end

  defp resize_pty(state, cols, rows) do
    case Pty.resize(state.pty, cols, rows) do
      {:ok, pty} -> %{state | pty: pty, cols: cols, rows: rows}
      {:error, _reason} -> %{state | cols: cols, rows: rows}
    end
  end

  # ── access ───────────────────────────────────────────────────────────

  # Asked afresh: the session, then the track. The same two questions
  # `Ravix.Terminal.attach/5` asked before this process existed.
  defp recheck(state) do
    case allowed(state) do
      {:ok, expires_at} -> {:noreply, schedule_expiry(state, expires_at)}
      :error -> revoke(state)
    end
  end

  defp allowed(state) do
    with {:ok, %User{id: id}, expires_at} <- Accounts.open_session(state.session_hash),
         true <- id == state.user.id,
         {:ok, %{track: track}} <- Access.track_access(state.user, state.tab.track_id),
         true <- track.project_id == state.project_id and is_nil(track.closed_at) do
      {:ok, expires_at}
    else
      _ -> :error
    end
  end

  defp revoke(state) do
    state = flush(state)

    if state.tab.session_id do
      _ = Pty.kill(state.cfg, state.tab.sprite, state.tab.session_id)
    end

    forget(state)
    {:stop, :normal, ended(state, :revoked)}
  end

  # One timer for the session's own end. A later read that finds a later
  # expiry (the session was extended) moves it.
  defp schedule_expiry(state, %DateTime{} = at) do
    if state.expiry, do: Process.cancel_timer(state.expiry)
    ms = max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0)
    %{state | expiry: Process.send_after(self(), :expired, min(ms, 4_294_967_295))}
  end

  # ── the page ─────────────────────────────────────────────────────────

  defp forget(state), do: Store.delete(state.tab.id, state.user.id)

  defp ended(state, reason) do
    notify(state, {:ended, reason})
    %{state | owner: nil}
  end

  defp disconnected(state) do
    notify(state, :disconnected)
    %{state | owner: nil}
  end

  defp notify(%{owner: nil}, _event), do: :ok
  defp notify(state, event), do: send(state.owner, {:terminal, state.tab.id, event})
end

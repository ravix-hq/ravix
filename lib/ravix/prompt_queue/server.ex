defmodule Ravix.PromptQueue.Server do
  @moduledoc """
  One worker for this deployment, delivering saved prompts to Fountain.

  No browser connection participates in delivery. A sweep takes the first
  live row of every thread, checks the sender still has access, asks
  Fountain whether the previous delivered turn settled, refreshes the clone credential,
  and only then claims the row and POSTs it. A claim is taken immediately
  before the POST; after a crash or an ambiguous response the payload is
  retained but never replayed blindly. The server serializes claims and POST
  permission with shutdown; a draining instance returns preparers to queued,
  allows POSTs four seconds to settle, then leaves ambiguous sends to recovery.
  It stops before the endpoint, with an explicit five-second child budget.

  Sweeps run every thirty seconds as a backstop and immediately whenever a
  prompt is saved or retried (`wake/0`, heard by every instance) or a
  thread with a waiting prompt says a turn has settled. The worker holds a
  real follower subscription for each queued head, even without a browser.
  A prompt held back by a busy agent
  therefore goes out as that turn ends rather than on the next tick, and the
  timer remains the backstop when a stream is unavailable, a broadcast is
  missed, or the instance that heard it leaves. Both paths run the same
  idempotent sweep, and `Store.claim/1`
  decides which instance actually sends.

  Threads are delivered in parallel, one task each under
  `Ravix.TaskSupervisor`, so a thread whose Fountain call is slow does not
  hold the others; a task that crashes leaves its row for the next sweep.
  A failed or unconfirmed head is not delivered and holds its thread: later
  instructions cannot overtake one whose outcome needs a person. Other
  threads still advance.

  Every prompt goes out with its row id as Fountain's `client_request_id`,
  which Fountain copies onto the turn it opens. So an `:unconfirmed` head --
  a POST whose answer never came, or a claim `Store.recover/0` took back --
  is looked up once in the conversation's turns: found, it was delivered and
  is recorded as such; not found, it stays `:unconfirmed` and says what was
  looked for. It is never re-sent from here: the id is a correlation, not an
  idempotency key, and a POST Fountain is still working on may not have made
  its turn yet.

  Recovery (`Ravix.PromptQueue.Store.recover/0`) runs at the start of the first
  sweep rather than in `init/1`, so that starting the process touches no
  database; the first sweep is one interval after start. `tick/1` runs a
  sweep now and returns when it is done, which is what tests drive instead
  of waiting on the timer.

  Options to `start_link/1`: `:name` (default this module), `:interval`
  in milliseconds between sweeps that find nothing waiting (default 30000;
  `false` for no timer at all, for tests), and `:busy_interval`, the shorter
  gap used while a prompt waits (default 30000, and never longer than
  `:interval`; shorter still when a track's setup check falls due sooner), and `:wake` (default true), whether to sweep on `wake/0`;
  tests that drive `tick/1` turn it off so another test's save cannot
  start a sweep under them.
  """

  use GenServer, shutdown: 5_000

  require Logger

  alias Ravix.Accounts.Access
  alias Ravix.Accounts.User
  alias Ravix.Analytics
  alias Ravix.Fountain
  alias Ravix.Fountain.Client
  alias Ravix.Fountain.Error
  alias Ravix.Fountain.Shapes
  alias Ravix.Hub
  alias Ravix.Projects.Project
  alias Ravix.Projects.ProjectMember
  alias Ravix.PromptQueue
  alias Ravix.PromptQueue.Activity
  alias Ravix.PromptQueue.Body
  alias Ravix.PromptQueue.Item
  alias Ravix.PromptQueue.Recovery
  alias Ravix.PromptQueue.Store
  alias Ravix.Repo
  alias Ravix.SessionConfig
  alias Ravix.Trace
  alias Ravix.Tracks.Attribution
  alias Ravix.Tracks.Billing
  alias Ravix.Tracks.CredentialRecovery
  alias Ravix.Tracks.Follower
  alias Ravix.Tracks.Sandbox
  alias Ravix.Tracks.Sandbox.Maintenance
  alias Ravix.Tracks.Setup
  alias Ravix.Tracks.Track
  alias Ravix.Tracks.TrackMember
  alias Ravix.Tracks.Transcript
  alias Ravix.Tracks.Transcript.Event

  import Ecto.Query, only: [from: 2]

  @interval 30_000
  # Followers deliver settle events even without a browser. Poll only as a
  # backstop for missed events or a temporarily unavailable stream.
  @busy_interval 30_000
  # A per-head backstop, not a sweep deadline: the HTTP client defaults to
  # 60 seconds, but readiness/preview work may also take time. A task killed
  # here cannot settle its claim. Store.recover detects departed owners or
  # waits six minutes on a live owner, marking it unconfirmed, never replaying it.
  @delivery_timeout 5 * 60_000
  @wake_topic "prompt_queue:wake"

  @ended "This conversation has ended. Add a new thread and copy this prompt there."
  # For a conversation that failed before it ever ran a turn. `@ended` tells
  # somebody to start a new track and copy the prompt there, which is right for
  # a conversation that finished and wrong -- circular, even -- for one whose
  # machine could not be built: the new track fails the same way (#35).
  @never_started "The machine for this track could not be started, so the prompt was not sent."
  @waiting "Waiting for the machine connection. Your prompt is saved and will retry automatically."
  @refused "The machine service refused this prompt. Retry it in a moment; if it is refused again, contact the project owner."
  @unconfirmed "Delivery could not be confirmed. Check the transcript before sending this again."
  # Only what was looked for, not a verdict: a prompt sent before rows carried
  # their id (or by an older instance mid-deploy) has none to find.
  @not_arrived "The machine service has no record of receiving this prompt. Check the transcript, then retry it if it is still needed."

  @type option ::
          {:name, GenServer.name() | nil}
          | {:interval, pos_integer() | false}
          | {:busy_interval, pos_integer()}
          | {:wake, boolean()}

  @doc "Start the worker. See the module for the options."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "The maximum lifetime of one supervised delivery task, including readiness; not a global sweep deadline."
  def delivery_timeout_ms, do: @delivery_timeout

  @doc "Run one sweep now and return once every head has been handled."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, @delivery_timeout + 1_000)

  @doc """
  Tell every instance's worker a prompt is waiting, so it sweeps now rather
  than on its timer. Without this a prompt on an idle thread -- no earlier
  head followed, so no settle event coming -- sat until the next backstop
  tick, up to thirty seconds. Every instance hears it and sweeps, and
  `Store.claim/1` still decides which one sends.
  """
  @spec wake() :: :ok
  def wake, do: Phoenix.PubSub.broadcast(Ravix.PubSub, @wake_topic, :prompt_queued)

  @doc "The topic `wake/0` broadcasts `:prompt_queued` on, for a test that listens for one."
  @spec wake_topic() :: String.t()
  def wake_topic, do: @wake_topic

  @doc "Stop claiming, release preparers, and drain in-flight POSTs within the shutdown budget."
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__), do: GenServer.stop(server, :shutdown)

  # ── callbacks ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    if Keyword.get(opts, :wake, true), do: Phoenix.PubSub.subscribe(Ravix.PubSub, @wake_topic)

    state = %{
      interval: Keyword.get(opts, :interval, @interval),
      busy_interval: Keyword.get(opts, :busy_interval, @busy_interval),
      following: %{},
      running: nil,
      # When the soonest setup check not yet due falls due, from the last sweep.
      next_setup: nil,
      # A wake that arrives mid-sweep may name a row that sweep already
      # missed, so it earns one more sweep as soon as this one finishes.
      again?: false,
      timer: nil,
      callers: [],
      claims: %{},
      # Nothing is known until the first sweep, and a restart is exactly when
      # something may be waiting: a prompt the instance that went away had
      # queued, or a claim `Store.recover/0` has to take back. So the first
      # sweep is the near one, and what it finds decides the next.
      waiting?: true
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:tick, from, state) do
    {:noreply, start_sweep(%{state | callers: [from | state.callers]})}
  end

  def handle_call({:heads, heads, due_setups?}, _from, state) do
    state = follow(state, heads)
    {:reply, :ok, %{state | waiting?: state.waiting? or due_setups?}}
  end

  def handle_call({:heads, heads, due_setups?, next_setup}, from, state) do
    handle_call({:heads, heads, due_setups?}, from, %{state | next_setup: next_setup})
  end

  # Claim and POST permission are serialized with supervisor shutdown. Once
  # terminate starts no worker can pass either gate, even if readiness finishes.
  def handle_call({:claim, id, token}, {pid, _}, state) do
    if Store.claim(id, token) do
      claim = %{id: id, token: token, phase: :preparing, ref: Process.monitor(pid)}
      {:reply, true, %{state | claims: Map.put(state.claims, pid, claim)}}
    else
      {:reply, false, state}
    end
  end

  def handle_call({:post, token}, {pid, _}, state) do
    case state.claims[pid] do
      %{token: ^token} = claim ->
        allowed = Store.begin_post(claim.id, token)
        claim = if allowed, do: %{claim | phase: :posting}, else: claim
        {:reply, allowed, %{state | claims: Map.put(state.claims, pid, claim)}}

      _ ->
        {:reply, false, state}
    end
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, start_sweep(state)}
  def handle_info(:prompt_queued, state), do: {:noreply, wake_sweep(state)}

  def handle_info({ref, _result}, %{running: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_sweep(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref}} = state) do
    Logger.error("ravix: prompt sweep crashed: #{inspect(reason)}")
    {:noreply, finish_sweep(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {claim, claims} = Map.pop(state.claims, pid)
    release_prepared(claim)
    state = %{state | claims: claims}

    case Enum.find(state.following, fn {_id, monitor} -> monitor == ref end) do
      nil ->
        {:noreply, state}

      {id, _} ->
        Follower.unsubscribe(id)
        {:noreply, start_sweep(%{state | following: Map.delete(state.following, id)})}
    end
  end

  # A followed thread's transcript. A settled turn is the moment its
  # conversation can take the next prompt, so sweep then rather than wait out
  # the timer; every other event on the topic is somebody else's business.
  # Sweeping rather than delivering this one thread keeps one delivery path:
  # the sweep is idempotent and already claims each row before it sends, so a
  # broadcast both instances hear still sends once.
  def handle_info({:transcript, _thread_id, %Event{} = event}, state) do
    if Event.settles?(event), do: {:noreply, wake_sweep(state)}, else: {:noreply, state}
  end

  # A topic this server has just left can still have a message in flight, and
  # the sweep covers anything an event would have.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Kill preparers before releasing their fenced claims. POST workers may
    # finish for four seconds; the child has five seconds including DB cleanup.
    Enum.each(state.claims, fn {pid, claim} ->
      if claim.phase == :preparing do
        Process.exit(pid, :kill)
        release_prepared(claim)
      end
    end)

    if state.running do
      Task.yield(state.running, 4_000) || Task.shutdown(state.running, :brutal_kill)
    end

    Enum.each(state.claims, fn {pid, _claim} -> Process.exit(pid, :kill) end)
    Enum.each(state.callers, &GenServer.reply(&1, :ok))
    :ok
  end

  defp release_prepared(%{phase: :preparing, id: id, token: token}),
    do: Store.release_claim(id, token)

  defp release_prepared(_claim), do: :ok

  defp start_sweep(%{running: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    server = self()
    task = Task.Supervisor.async_nolink(Ravix.TaskSupervisor, fn -> sweep(server) end)
    # Only the sweep that finishes may say when setup is next due: one that
    # crashes must not leave a past time that reschedules it at once, forever.
    %{state | running: task, next_setup: nil}
  end

  defp start_sweep(state), do: state

  defp wake_sweep(%{running: nil} = state), do: start_sweep(state)
  defp wake_sweep(state), do: %{state | again?: true}

  defp finish_sweep(state) do
    Enum.each(state.callers, &GenServer.reply(&1, :ok))
    state = %{state | running: nil, callers: []}

    if state.again?,
      do: start_sweep(%{state | again?: false}),
      else: schedule(state)
  end

  defp schedule(%{interval: false} = state), do: state

  defp schedule(%{interval: interval, waiting?: waiting?} = state) do
    delay = if waiting?, do: min(interval, state.busy_interval), else: interval
    delay = until_setup(state.next_setup, delay)
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, delay)}
  end

  # Be there when a setup check falls due rather than up to a backstop later,
  # a little after it so the check is due when the sweep lists it.
  defp until_setup(nil, delay), do: delay

  defp until_setup(at, delay),
    do:
      at
      |> DateTime.diff(DateTime.utc_now(), :millisecond)
      |> Kernel.+(50)
      |> max(100)
      |> min(delay)

  # ── the sweep ─────────────────────────────────────────────────────────

  defp sweep(server) do
    # Untraced (ADR 0004). This runs on every instance and almost always finds
    # nothing: `Store.recover/0` and `Store.heads/0` with no
    # parent span would be two root traces per sweep, tens of thousands of empty
    # traces a day per instance, at Honeycomb's per-event price. Suppression
    # covers this process only, so each `deliver/2` -- which runs in its own
    # task under `deliver_heads/2` -- still gets the trace that is worth having.
    Trace.untraced(fn ->
      # Every sweep, not once at boot. A claim can outlive the task holding it
      # -- killed for running long, or lost between the POST and the status
      # write -- and `:sending` is refused by both `cancel/3` and `retry/3`, so
      # nothing else would ever take it back. `Store.recover/0` only
      # reclaims departed-node claims promptly, with the age limit as a backstop.
      # POST permission is fenced in the database against a recovered claim.
      Store.recover()
      client = Fountain.client()

      if Client.configured?(client), do: deliver_heads(client, server), else: :ok
    end)
  rescue
    # Leave claims intact for explicit recovery, and retry untouched rows on
    # the next sweep. Never log prompt bodies or manufacture a successful send.
    error ->
      Logger.error("ravix: prompt queue sweep failed: #{Exception.message(error)}")
      :ok
  end

  defp deliver_heads(client, server) do
    # ownership: no door — background setup recovery has no user in hand. Store lists
    # only due live tracks; its durable leases serialize all instances and retries.
    setups = MapSet.new(Ravix.Tracks.Store.pending_setups())
    heads = Store.heads()
    # Subscribe before delivery so a settling turn cannot race the sweep.
    :ok = GenServer.call(server, {:heads, heads, MapSet.size(setups) > 0})
    represented = MapSet.new(heads, & &1.track_id)

    jobs =
      Enum.map(heads, &{:head, &1}) ++
        Enum.map(MapSet.difference(setups, represented), &{:setup, &1})

    Ravix.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(jobs, &run_job(client, &1, setups, server),
      ordered: false,
      timeout: @delivery_timeout,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, _outcome} -> :ok
      {:exit, reason} -> Logger.error("ravix: prompt delivery crashed: #{inspect(reason)}")
    end)

    # Release subscriptions as soon as a head settles instead of holding
    # otherwise idle streams until the next backstop sweep.
    # ownership: no door, as for `pending_setups/0` above; a time, not a row.
    next_setup = Ravix.Tracks.Store.next_setup_due()
    GenServer.call(server, {:heads, Store.heads(), MapSet.size(setups) > 0, next_setup})
    :ok
  end

  defp run_job(client, {:setup, id}, _setups, _server), do: advance_setup(client, id)

  defp run_job(client, {:head, row}, setups, server) do
    if MapSet.member?(setups, row.track_id), do: advance_setup(client, row.track_id)
    deliver(client, row, server)
  end

  # A setup check this sweep found due, and -- when it is the check that
  # found the opening turn finished on a track with its own machine -- the
  # machine recorded ready in the same breath, so that `deliver/3` below
  # sends the prompt now rather than after the sandbox reconciler's next pass
  # and this worker's next backstop (RAV-131). Both are leased, idempotent,
  # and do nothing when another instance or the reconciler holds the lease.
  # ownership: no door, as for `pending_setups/0` above; the setup lease and
  # the operation lease are the write authorities.
  defp advance_setup(client, id) do
    Setup.advance(client, id)
    Sandbox.finish_open(client, id)
  end

  # Which threads this server listens to, and whether anything is waiting at
  # all. A follower broadcasts a thread's events on `Follower.topic/1` keyed by
  # the *thread*, not the track it belongs to, so a second thread's turn is a
  # different topic from its track's first; joining a track's would hear
  # nothing after #164.
  #
  # Joining is not idempotent -- `Phoenix.PubSub` registers one subscription
  # per call, so joining again each sweep would deliver every event of every
  # such thread once per sweep that ever ran, forever -- so the topics joined
  # are what this holds, and each is joined once and left when its thread's
  # head is gone.
  #
  # Only a `:queued` head is worth either: a failed or unconfirmed head waits
  # for a person, and waking on a turn (or sweeping twice as often) does not
  # make a person answer sooner.
  defp follow(state, heads) do
    wanted = for %Item{status: :queued} = row <- heads, into: MapSet.new(), do: row.thread_id

    following =
      Enum.reduce(state.following, state.following, fn {id, ref}, acc ->
        if MapSet.member?(wanted, id) do
          acc
        else
          Follower.unsubscribe(id)
          Process.demonitor(ref, [:flush])
          Map.delete(acc, id)
        end
      end)

    following = Enum.reduce(wanted, following, &join_follower/2)
    %{state | following: following, waiting?: not Enum.empty?(wanted)}
  end

  defp join_follower(id, following) when is_map_key(following, id), do: following

  defp join_follower(id, following) do
    # ownership: a queued head belongs to this thread; delivery below
    # rechecks its sender's access before sending anything to Fountain.
    case Follower.subscribe(id) do
      {:ok, pid} ->
        Map.put(following, id, Process.monitor(pid))

      {:error, _} ->
        Follower.unsubscribe(id)
        following
    end
  end

  # ── one head ──────────────────────────────────────────────────────────

  defp deliver(client, %Item{} = row, server) do
    # A trace root: a delivery is background work that nothing clicked, and this
    # task's context is fresh, so the sweep's suppression does not reach it. One
    # trace per prompt actually delivered is a volume worth paying for, which
    # the sweep itself is not.
    Trace.span(
      "prompt_queue.deliver",
      %{"ravix.track_id" => row.track_id, "ravix.queue_item_status" => row.status},
      fn ->
        outcome = outcome(client, row, server)

        # `:ok`, `:held`, `:waiting`, `:lost_claim`, `:confirmed` or
        # `:not_arrived` -- never a tagged error, so
        # `span/3` cannot read it from the return value. It is the attribute
        # somebody debugging a stuck prompt is looking for: `:waiting` and
        # `:held` both mean the row is still queued and the next sweep will try
        # again, which is indistinguishable from `:ok` on a duration alone.
        Trace.annotate(%{"ravix.delivery_outcome" => outcome})
        outcome
      end
    )
  end

  # Cancelled when the sender may not send any more; otherwise what the row's
  # status calls for, on the track and project the access check loaded.
  defp outcome(client, row, server) do
    case access(row) do
      :revoked -> cancel(row)
      {:ok, track, project} -> deliver(client, row, track, project, server)
    end
  end

  defp deliver(client, row, track, project, server) do
    cond do
      unchecked?(row) ->
        confirm(client, row, track, project)

      row.status != :queued ->
        :held

      track.setup_state == "failed" ->
        Store.fail_setup(
          track.id,
          Setup.failure_message() <> " " <> Fountain.Error.reason_message(track.setup_error),
          track.setup_error_code
        )

      track.setup_state != "ready" or
          (track.sandbox_layout == :dedicated and track.sandbox_state != :ready) ->
        :waiting

      true ->
        deliver_queued(client, row, track, project, server)
    end
  end

  # `track` and `project` are the rows `access/1` loaded to decide the sender
  # may send: what to send it to, without a second read of either.
  defp deliver_queued(client, row, track, project, server) do
    readiness =
      with :ok <- billing_hold(track, project, row),
           :ok <- CredentialRecovery.prepare(client, track, project, row.thread_id) do
        readiness(client, track, project, row)
      else
        {:paused, message} -> {:paused, message}
        _ -> :recovering_credentials
      end

    case readiness do
      {:paused, message} ->
        Store.annotate(row.id, :queued, message)
        :waiting

      :recovering_credentials ->
        Store.annotate(
          row.id,
          :queued,
          "Updating this thread's agent connection. Your prompt is saved."
        )

        :waiting

      :ready ->
        claim_and_send(client, row, track, project, server)

      :busy ->
        Store.annotate(row.id, :queued, Ravix.PromptQueue.busy_wait())
        :waiting

      {:ended, message} ->
        Store.set_status(row.id, :failed, message)

      :unavailable ->
        hold(row)
    end
  end

  # A creator-billed track's harness waits while its payer's credential is
  # paused (`Ravix.Tracks.Billing`): the prompt stays queued, saying why, and
  # goes out once the creator reconnects or tries again. Nobody else's
  # credential is tried meanwhile.
  defp billing_hold(track, project, row) do
    if Track.creator_billed?(track),
      do: payer_hold(track, project, thread_runtime(row, project)),
      else: :ok
  end

  defp payer_hold(track, project, runtime) do
    with {:ok, payer} <- Billing.payer(track, project),
         %{} = pause <- Billing.paused(track, runtime, payer) do
      {:paused, Billing.message(pause)}
    else
      nil -> :ok
      {:error, {_kind, _code, message}} -> {:paused, message}
    end
  end

  defp thread_runtime(row, project) do
    # ownership: access/1 established Access.thread_access for this queue row.
    thread = Ravix.Tracks.Store.get_thread(row.thread_id)
    (thread && thread.runtime) || Project.home_runtime(project)
  end

  # An unconfirmed row nobody has looked for yet. After one look that found
  # nothing, the message says so and the row waits for a person, so a track
  # whose prompt was lost does not read Fountain's turns on every sweep.
  defp unchecked?(%Item{status: :unconfirmed, error: error}), do: error != @not_arrived
  defp unchecked?(%Item{}), do: false

  # Did the POST we could not hear back from arrive? Fountain's answer, read
  # off the turns by the id we sent. A read that fails leaves the row as it
  # is for the next sweep. `track` and `project` are the rows `access/1`
  # loaded: where the row was sent, without reading either again.
  defp confirm(client, row, track, project) do
    case Fountain.turns(client, track.conversation_id) do
      {:ok, turns} ->
        if Enum.any?(turns, &(&1.client_request_id == row.id)) do
          settle(:ok, row, track, project)
          :confirmed
        else
          Store.annotate(row.id, :unconfirmed, @not_arrived)
          :not_arrived
        end

      {:error, _reason} ->
        :held
    end
  end

  # Nothing has been sent yet at this point. A read or credential refresh
  # that failed can safely retry on the next sweep.
  defp readiness(client, track, project, row) do
    case Fountain.get_conversation(client, track.conversation_id) do
      {:ok, conversation} ->
        guest? = guest_thread?(track, project, row)

        cond do
          busy_conversation?(client, track, row, conversation, guest?) ->
            :busy

          Shapes.ended?(conversation) and
              not CredentialRecovery.enabled?(track, project) ->
            {:ended, ended_message(client, track, conversation)}

          true ->
            receipt_readiness(client, project, track, row, guest?)
        end

      {:error, _reason} ->
        :unavailable
    end
  end

  defp busy_conversation?(client, track, row, conversation, guest?) do
    (track.sandbox_layout == :shared or guest?) and Shapes.busy?(conversation) and
      not blank_thread?(client, row, conversation)
  end

  defp guest_thread?(%{sandbox_layout: :dedicated} = track, project, row) do
    # ownership: access/1 established Access.thread_access for this queue row.
    thread = Ravix.Tracks.Store.get_thread(row.thread_id)
    Activity.guest?(track, project, thread)
  end

  defp guest_thread?(_track, _project, _row), do: false

  defp receipt_readiness(client, project, track, _row, false),
    do: machine_readiness(client, project, track)

  defp receipt_readiness(client, project, track, row, true) do
    receipt = Store.latest_delivered(row.thread_id, track.conversation_id)

    case Activity.state(client, track.conversation_id, receipt) do
      state when state in [:pending, :running] ->
        :busy

      :unavailable ->
        :unavailable

      :expired ->
        Store.annotate(
          row.id,
          :queued,
          "The previous turn has not appeared or started after two minutes. Using the conversation status to try this prompt."
        )

        machine_readiness(client, project, track)

      _ ->
        machine_readiness(client, project, track)
    end
  end

  # An attached thread has no launch prompt. Fountain can call it pending
  # until its first turn, which is different from a pending turn already owed.
  defp blank_thread?(client, %{thread_id: thread_id, track_id: track_id}, %Shapes.Conversation{
         status: :pending,
         turn_count: 0,
         id: id
       })
       when thread_id != track_id do
    match?({:ok, []}, Fountain.turns(client, id))
  end

  defp blank_thread?(_client, _row, _conversation), do: false

  # Why it ended, in Fountain's own words when it has any.
  #
  # A conversation that never ran a turn did not "end" in any sense a person
  # would recognise -- it failed to start, and the reason is on the stage event
  # that failed. Worth one extra read on a path that is already terminal: the
  # deployment that found this was refused by Sprites for want of a credit card,
  # and said so, and none of it reached the screen (#35).
  defp ended_message(client, track, conversation) do
    # Only a turn count we were actually given. A missing one means Fountain did
    # not say, which is not the same as zero, and guessing "never started" for a
    # conversation that may have run for an hour would be its own wrong message.
    if conversation.turn_count == 0 do
      case failure_reason(client, track.conversation_id) do
        nil -> @never_started
        reason -> @never_started <> " " <> reason
      end
    else
      @ended
    end
  end

  defp failure_reason(client, conversation_id) do
    with {:ok, events} <- Fountain.events(client, conversation_id),
         %Event{} = event <- last_failed_stage(events) do
      case Transcript.failure_reason(event) do
        "" -> nil
        reason -> reason
      end
    else
      _ -> nil
    end
  rescue
    # A prompt held for a reason we could not fetch still gets the plain
    # message; the sweep must not crash over an explanation.
    _error -> nil
  end

  # The most recent stage that failed, parsed at this boundary as everywhere
  # else Fountain's log is read.
  defp last_failed_stage(events) do
    events
    |> Enum.reverse()
    |> Stream.map(&Event.from/1)
    |> Enum.find(&Event.failed_stage?/1)
  end

  defp machine_readiness(client, project, track) do
    case Maintenance.prepare(client, track, project) do
      :ok -> :ready
      {:error, _reason} -> :unavailable
    end
  end

  defp hold(row) do
    case Store.get(row.id) do
      %Item{status: :queued} -> Store.set_status(row.id, :queued, @waiting)
      _ -> :ok
    end
  end

  # Membership and cancellation may change during the network calls above.
  defp claim_and_send(client, row, track, project, server) do
    row = %{row | claim_token: Ecto.UUID.generate()}

    cond do
      not authorized?(row) -> cancel(row)
      not GenServer.call(server, {:claim, row.id, row.claim_token}) -> :lost_claim
      true -> send_claimed(client, row, track, project, server)
    end
  end

  defp send_claimed(client, row, track, project, server) do
    outcome =
      try do
        post(client, row, track, project, server)
      rescue
        error -> {:error, {:crashed, error}}
      catch
        kind, value -> {:error, {kind, value}}
      end

    settle(outcome, row, track, project)
  end

  # Re-read rather than taken from `row`: the sweep picked that up before the
  # network calls above, and a cancellation since then has released the body.
  defp post(client, row, track, project, server) do
    body = row.id |> Store.get() |> Map.fetch!(:body) |> Body.decode()
    instructions = Ravix.Previews.prepare_agent_preview(row)

    prompt = Body.in_thread(body.prompt, row, track)

    with {:ok, preamble} <- Recovery.prepare(client, row, track, project),
         true <- authorized?(row) do
      # Who the thread's commits credit (ADR 0009 phase 4c); "" to leave the
      # prompt as it was.
      attribution = Attribution.delivery_block(track, row.thread_id)

      text =
        compose(
          preamble,
          compose(instructions, compose(attribution, authored(row, track, project, prompt)))
        )

      if GenServer.call(server, {:post, row.claim_token}) do
        Fountain.prompt(client, track.conversation_id, text, body.images,
          client_request_id: row.id,
          session_config: session_config(row)
        )
      else
        # Discovery lag may have recovered this live preparer's claim. Its
        # fenced token and absent POST permission prove this attempt is safe
        # to release now, without waiting for the server's DOWN notification.
        Store.release_claim(row.id, row.claim_token)
        :lost_claim
      end
    else
      false -> :revoked
      error -> error
    end
  end

  # RAV-52: the thread's ACP session config options (effort, Fast), on every
  # prompt. Fountain applies a prompt's options to that turn only (ADR 0062),
  # so the thread's stored choice is the whole of it each time.
  defp session_config(row) do
    # ownership: access/1 established Access.thread_access for this queue row.
    case Ravix.Tracks.Store.thread(row.track_id, row.thread_id) do
      %{session_config: config} -> SessionConfig.clean(config)
      nil -> %{}
    end
  end

  defp settle(:lost_claim, _row, _track, _project), do: :lost_claim

  defp settle(:ok, row, track, project) do
    Store.mark_delivered(row.id, track.conversation_id)
    # ownership: access/1 established Access.thread_access before this confirmed delivery.
    if CredentialRecovery.enabled?(track, project),
      do: Ravix.Tracks.Store.credential_context_delivered(row.thread_id, track.conversation_id)

    Hub.publish(project.id, :turn, track_id: track.id, thread_id: row.thread_id)
    delivered(row, track, project)
  end

  defp settle({:error, :context_unavailable}, row, _track, _project),
    do:
      Store.set_status(
        row.id,
        :queued,
        "Waiting for the thread's session history before sending."
      )

  defp settle(:revoked, row, track, _project) do
    cancel(row)
    # ownership: `access/1` just re-asked `Access.track_access/2` for the
    # sender and was refused, and the helper grant minted for their turn must
    # not outlive their seat. Whoever holds it, hence the explicit nil.
    Ravix.Previews.Store.revoke_agent(track.id, nil)
  end

  # Fountain can reject an idle-looking track because another turn took the
  # sandbox's capacity meanwhile. A rejection is safe to retry. Any other
  # refusal needs a person; anything else may or may not have arrived.
  defp settle({:error, %Error{} = error}, row, track, project) do
    case creator_refusal(error, row, track, project) do
      :none -> settle_refusal(error, row, track, project)
      settled -> settled
    end
  end

  defp settle({:error, _reason}, row, _track, _project),
    do: Store.set_status(row.id, :unconfirmed, @unconfirmed)

  # A creator-billed track's refusals of its payer's credential keep the
  # prompt queued with the reason; nothing is tried on anybody else's.
  defp creator_refusal(error, row, track, project) do
    cond do
      pause = creator_pause(error, row, track, project) ->
        Store.set_status(row.id, :queued, Billing.message(pause), error.code)

      error.code == "inference_credential_not_allowed" and Track.creator_billed?(track) ->
        Store.set_status(
          row.id,
          :queued,
          "Waiting for this track's agent to admit its creator's account. Your prompt is saved.",
          error.code
        )

      true ->
        :none
    end
  end

  defp settle_refusal(error, row, track, project) do
    cond do
      error.code == "inference_source_changed" and
          CredentialRecovery.enabled?(track, project) ->
        CredentialRecovery.reject(track, project, row.thread_id)

        Store.set_status(
          row.id,
          :queued,
          "Updating this thread's agent connection. Your prompt is saved.",
          error.code
        )

      Error.credential?(error) ->
        Store.set_status(row.id, :failed, Error.credential_message(), error.code)

      # Only the map's shape is checked there, so this is a stored choice that
      # no longer fits Fountain's rules. The person changes it and resends.
      error.code == "session_config_invalid" ->
        Store.set_status(
          row.id,
          :failed,
          "Fountain refused this thread's effort or Fast setting. Change it in the model menu, then send again.",
          error.code
        )

      Error.busy?(error) ->
        Store.set_status(row.id, :queued, "The agent is at capacity; will retry", error.code)

      Error.rejected?(error) ->
        Store.set_status(row.id, :failed, @refused)

      true ->
        Store.set_status(row.id, :unconfirmed, @unconfirmed)
    end
  end

  # A refusal of a creator-billed track's payer's credential pauses the
  # harness on the track, and the prompt waits rather than failing.
  defp creator_pause(error, row, track, project) do
    with true <- Track.creator_billed?(track),
         {:ok, payer} <- Billing.payer(track, project),
         runtime = thread_runtime(row, project),
         %{} = pause <- Billing.from_error(error, payer, runtime) do
      Billing.pause(track, runtime, pause)
      pause
    else
      _ -> nil
    end
  end

  # The prompt reached the agent. Attributed to whoever sent it, which the row
  # records, and carrying the wait -- a prompt accepted while the agent was busy
  # can sit here for minutes, and that wait is what somebody describing "the
  # agent is slow" is usually describing.
  #
  # This runs in a delivery task rather than in a request, so the user read is
  # one nobody is waiting on. Skipped entirely when the sender has since been
  # deleted: a person who is gone is not a person to file an event against.
  defp delivered(row, track, project) do
    # ownership: the row's own `user_id`, and `authorized?/1` put this person
    # through `Access.track_access/2` for this track before the prompt was
    # sent. Read again only to say whose event this is.
    Analytics.track(
      Ravix.Accounts.Store.get_user(row.user_id),
      :prompt_delivered,
      track
      |> Analytics.repo(project)
      |> Map.merge(Analytics.waited_ms(row.created_at))
      |> Map.put("ravix.image_count", row.image_count)
    )
  end

  defp cancel(row), do: Store.set_status(row.id, :cancelled)

  defp compose("", authored), do: authored
  defp compose(instructions, authored), do: instructions <> "\n\n" <> authored

  # On a shared track the agent is told who is speaking (shared/author.ts).
  defp authored(row, track, project, prompt) do
    if shared?(track, project),
      do: PromptQueue.with_author(row.author_login, prompt),
      else: prompt
  end

  # ownership: `authorized?/1` in `deliver/2` put the row's sender through
  # `Access.track_access/2` before this is asked. It reads whether anybody
  # besides the owner can see the track, which decides only whether the agent
  # is told who is speaking -- not an access decision; `authorized?/1` is.
  defp shared?(track, project) do
    Repo.exists?(from(m in TrackMember, where: m.track_id == ^track.id)) or
      Repo.exists?(from(m in ProjectMember, where: m.project_id == ^project.id)) or
      Access.workspace_shared?(track, project)
  end

  # The sender still exists, still has the track, and the track is open with
  # a conversation to deliver into. The track and the project that decided it
  # come back with the answer: `Access.track_access/2` had to load both to
  # decide, and they are what delivery needs next, so delivery is handed them
  # rather than reading the same two rows again.
  defp access(row) do
    # ownership: no door before this one -- it is the door. A queued prompt
    # outlives the request that made it, so who sent it is re-established
    # here rather than trusted from whenever it was accepted: the row's own
    # `user_id` becomes the person `Access.track_access/2` is asked about.
    with %User{} = user <- Ravix.Accounts.Store.get_user(row.user_id),
         # A sender whose role has since dropped to read (ADR 0010) no longer
         # sends: what they queued is revoked as a removal's would be.
         {:ok, %{track: track, project: project, thread: thread}} <-
           Access.thread_access(user, row.track_id, row.thread_id, :write),
         true <- is_nil(thread.closed_at),
         track = %{track | conversation_id: thread.conversation_id},
         true <- open?(track) do
      {:ok, track, project}
    else
      _ -> :revoked
    end
  end

  defp open?(track),
    do:
      is_nil(track.closed_at) and track.sandbox_state not in [:closing, :terminated] and
        (track.sandbox_layout == :dedicated or
           (is_binary(track.conversation_id) and track.conversation_id != ""))

  # The same question asked again, where only the answer matters: membership
  # and cancellation may change during the network calls, so it is asked once
  # more before the claim and once more before the POST. The rows those
  # steps use are the ones `access/1` loaded; a change to either since then
  # is a change to who may send, which this is what catches.
  defp authorized?(row) do
    case access(row) do
      {:ok, %{sandbox_layout: :dedicated} = track, project} ->
        track.setup_state == "ready" and track.secrets_generation == project.secrets_generation and
          not project.secrets_pending

      {:ok, _track, _project} ->
        true

      _ ->
        false
    end
  end
end

defmodule Ravix.PromptQueue.Server do
  @moduledoc """
  One worker for this deployment, delivering saved prompts to Fountain.

  No browser connection participates in delivery. Every two seconds the
  server takes the first live row of every track, checks the sender still
  has access, asks Fountain whether the conversation is idle, refreshes the
  clone credential, and only then claims the row and POSTs it. A claim is
  taken immediately before the POST; after a crash or an ambiguous response
  the payload is retained but never replayed blindly.

  Tracks are delivered in parallel, one task each under
  `Ravix.TaskSupervisor`, so a track whose Fountain call is slow does not
  hold the others; a task that crashes leaves its row for the next sweep.
  A failed or unconfirmed head is not delivered and holds its track: later
  instructions cannot overtake one whose outcome needs a person. Other
  tracks still advance.

  Every prompt goes out with its row id as Fountain's `client_request_id`,
  which Fountain copies onto the turn it opens. So an `:unconfirmed` head --
  a POST whose answer never came, or a claim `Store.recover/0` took back --
  is looked up once in the conversation's turns: found, it was delivered and
  is recorded as such; not found, it stays `:unconfirmed` and says what was
  looked for. It is never re-sent from here: the id is a correlation, not an
  idempotency key, and a POST Fountain is still working on may not have made
  its turn yet.

  Recovery (`Ravix.Store.recover/0`) runs at the start of the first
  sweep rather than in `init/1`, so that starting the process touches no
  database; the first sweep is one interval after start. `tick/1` runs a
  sweep now and returns when it is done, which is what tests drive instead
  of waiting on the timer.

  Options to `start_link/1`: `:name` (default this module), `:interval`
  in milliseconds (default 2000; `false` for no timer at all, for tests).
  """

  use GenServer

  require Logger

  alias Ravix.Accounts.{Access, User}
  alias Ravix.Analytics
  alias Ravix.Fountain
  alias Ravix.Fountain.{Client, Error, Shapes}
  alias Ravix.Hub
  alias Ravix.Projects.ProjectMember
  alias Ravix.PromptQueue
  alias Ravix.PromptQueue.Body
  alias Ravix.PromptQueue.Item
  alias Ravix.PromptQueue.Store
  alias Ravix.Repo
  alias Ravix.Trace
  alias Ravix.Tracks.{TrackMember, Transcript}
  alias Ravix.Tracks.Transcript.Event

  import Ecto.Query, only: [from: 2]

  @interval 2_000
  # A backstop only: the Fountain client times out well inside this.
  @delivery_timeout 5 * 60_000

  @ended "This conversation has ended. Start a new track and copy this prompt there."
  # For a conversation that failed before it ever ran a turn. `@ended` tells
  # somebody to start a new track and copy the prompt there, which is right for
  # a conversation that finished and wrong -- circular, even -- for one whose
  # machine could not be built: the new track fails the same way (#35).
  @never_started "The machine for this track could not be started, so the prompt was not sent."
  @waiting "Waiting for the machine connection. Your prompt is saved and will retry automatically."
  @refused "Delivery was refused. Check the machine and account settings, then retry this prompt."
  @unconfirmed "Delivery could not be confirmed. Check the transcript before sending this again."
  # Only what was looked for, not a verdict: a prompt sent before rows carried
  # their id (or by an older instance mid-deploy) has none to find.
  @not_arrived "Fountain has no turn carrying this prompt's id. Check the transcript, then retry it if it is still needed."

  @type option :: {:name, GenServer.name() | nil} | {:interval, pos_integer() | false}

  @doc "Start the worker. See the module for the options."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "Run one sweep now and return once every head has been handled."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, @delivery_timeout + 1_000)

  @doc "Stop the worker. A sweep in progress finishes first."
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__), do: GenServer.stop(server)

  # ── callbacks ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    {:ok, schedule(%{interval: interval})}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, sweep(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> sweep() |> schedule()}

  defp schedule(%{interval: false} = state), do: state

  defp schedule(%{interval: interval} = state) do
    Process.send_after(self(), :tick, interval)
    state
  end

  # ── the sweep ─────────────────────────────────────────────────────────

  defp sweep(state) do
    # Untraced (ADR 0004). This runs every two seconds on every instance and
    # almost always finds nothing: `Store.recover/0` and `Store.heads/0` with no
    # parent span would be two root traces per sweep, tens of thousands of empty
    # traces a day per instance, at Honeycomb's per-event price. Suppression
    # covers this process only, so each `deliver/2` -- which runs in its own
    # task under `deliver_heads/1` -- still gets the trace that is worth having.
    Trace.untraced(fn ->
      # Every sweep, not once at boot. A claim can outlive the task holding it
      # -- killed for running long, or lost between the POST and the status
      # write -- and `:sending` is refused by both `cancel/3` and `retry/3`, so
      # nothing else would ever take it back. `Store.recover/0` only
      # reclaims claims older than `claim_timeout_ms/0`, so a task that is still
      # working is left alone.
      Store.recover()
      client = Fountain.client()

      if Client.configured?(client), do: deliver_heads(client)
    end)

    state
  rescue
    # Leave claims intact for explicit recovery, and retry untouched rows on
    # the next sweep. Never log prompt bodies or manufacture a successful send.
    error ->
      Logger.error("ravix: prompt queue sweep failed: #{Exception.message(error)}")
      state
  end

  defp deliver_heads(client) do
    Ravix.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(Store.heads(), &deliver(client, &1),
      ordered: false,
      timeout: @delivery_timeout,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, _outcome} -> :ok
      {:exit, reason} -> Logger.error("ravix: prompt delivery crashed: #{inspect(reason)}")
    end)
  end

  # ── one head ──────────────────────────────────────────────────────────

  defp deliver(client, %Item{} = row) do
    # A trace root: a delivery is background work that nothing clicked, and this
    # task's context is fresh, so the sweep's suppression does not reach it. One
    # trace per prompt actually delivered is a volume worth paying for, which
    # the sweep itself is not.
    Trace.span(
      "prompt_queue.deliver",
      %{"ravix.track_id" => row.track_id, "ravix.queue_item_status" => row.status},
      fn ->
        outcome = outcome(client, row)

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
  defp outcome(client, row) do
    case access(row) do
      :revoked -> cancel(row)
      {:ok, track, project} -> deliver(client, row, track, project)
    end
  end

  defp deliver(client, row, track, project) do
    cond do
      unchecked?(row) -> confirm(client, row, track, project)
      row.status != :queued -> :held
      true -> deliver_queued(client, row, track, project)
    end
  end

  # `track` and `project` are the rows `access/1` loaded to decide the sender
  # may send: what to send it to, without a second read of either.
  defp deliver_queued(client, row, track, project) do
    case readiness(client, track, project) do
      :ready -> claim_and_send(client, row, track, project)
      :busy -> :waiting
      {:ended, message} -> Store.set_status(row.id, :failed, message)
      :unavailable -> hold(row)
    end
  end

  # An unconfirmed row nobody has looked for yet. After one look that found
  # nothing, the message says so and the row waits for a person, so a track
  # whose prompt was lost does not read Fountain's turns every two seconds.
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
  defp readiness(client, track, project) do
    case Fountain.get_conversation(client, track.conversation_id) do
      {:ok, conversation} ->
        cond do
          Shapes.busy?(conversation) -> :busy
          Shapes.ended?(conversation) -> {:ended, ended_message(client, track, conversation)}
          # Idle, or a status this version does not know: either way nothing
          # is running, so whether a prompt can be sent is the machine's answer.
          true -> machine_readiness(client, project)
        end

      {:error, _reason} ->
        :unavailable
    end
  end

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

  defp machine_readiness(client, project) do
    case Ravix.Projects.prepare_machine(project, client) do
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
  defp claim_and_send(client, row, track, project) do
    cond do
      not authorized?(row) -> cancel(row)
      not Store.claim(row.id) -> :lost_claim
      true -> send_claimed(client, row, track, project)
    end
  end

  defp send_claimed(client, row, track, project) do
    outcome =
      try do
        post(client, row, track, project)
      rescue
        error -> {:error, {:crashed, error}}
      catch
        kind, value -> {:error, {kind, value}}
      end

    settle(outcome, row, track, project)
  end

  # Re-read rather than taken from `row`: the sweep picked that up before the
  # network calls above, and a cancellation since then has released the body.
  defp post(client, row, track, project) do
    body = row.id |> Store.get() |> Map.fetch!(:body) |> Body.decode()
    instructions = Ravix.Previews.prepare_agent_preview(row)

    if authorized?(row) do
      text = compose(instructions, authored(row, track, project, body.prompt))
      Fountain.prompt(client, track.conversation_id, text, body.images, client_request_id: row.id)
    else
      :revoked
    end
  end

  defp settle(:ok, row, track, project) do
    Store.mark_delivered(row.id)
    Hub.publish(project.id, :turn, track_id: track.id)
    delivered(row, track, project)
  end

  defp settle(:revoked, row, track, _project) do
    cancel(row)
    Ravix.Previews.revoke_agent(track.id, nil)
  end

  # Fountain can reject an idle-looking track because another turn took the
  # sandbox's capacity meanwhile. A rejection is safe to retry. Any other
  # refusal needs a person; anything else may or may not have arrived.
  defp settle({:error, %Error{} = error}, row, _track, _project) do
    cond do
      Error.busy?(error) -> Store.set_status(row.id, :queued)
      Error.rejected?(error) -> Store.set_status(row.id, :failed, @refused)
      true -> Store.set_status(row.id, :unconfirmed, @unconfirmed)
    end
  end

  defp settle({:error, _reason}, row, _track, _project),
    do: Store.set_status(row.id, :unconfirmed, @unconfirmed)

  # The prompt reached the agent. Attributed to whoever sent it, which the row
  # records, and carrying the wait -- a prompt accepted while the agent was busy
  # can sit here for minutes, and that wait is what somebody describing "the
  # agent is slow" is usually describing.
  #
  # This runs in a delivery task rather than in a request, so `Accounts.get_user/1`
  # is a read nobody is waiting on. Skipped entirely when the sender has since
  # been deleted: a person who is gone is not a person to file an event against.
  defp delivered(row, track, project) do
    Analytics.track(
      Ravix.Accounts.get_user(row.user_id),
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

  # ownership: whether anybody besides the owner can see this track, which
  # decides only whether the agent is told who is speaking. Not an access
  # decision; `authorized?/1` is.
  defp shared?(track, project) do
    Repo.exists?(from(m in TrackMember, where: m.track_id == ^track.id)) or
      Repo.exists?(from(m in ProjectMember, where: m.project_id == ^project.id))
  end

  # The sender still exists, still has the track, and the track is open with
  # a conversation to deliver into. The track and the project that decided it
  # come back with the answer: `Access.track_access/2` had to load both to
  # decide, and they are what delivery needs next, so delivery is handed them
  # rather than reading the same two rows again.
  defp access(row) do
    # ownership: this *is* the door. A queued prompt outlives the request that
    # made it, so who sent it is re-established here rather than trusted from
    # whenever it was accepted.
    with %User{} = user <- Ravix.Accounts.get_user(row.user_id),
         {:ok, %{track: track, project: project}} <- Access.track_access(user, row.track_id),
         true <- open?(track) do
      {:ok, track, project}
    else
      _ -> :revoked
    end
  end

  defp open?(track),
    do:
      is_nil(track.closed_at) and is_binary(track.conversation_id) and track.conversation_id != ""

  # The same question asked again, where only the answer matters: membership
  # and cancellation may change during the network calls, so it is asked once
  # more before the claim and once more before the POST. The rows those
  # steps use are the ones `access/1` loaded; a change to either since then
  # is a change to who may send, which this is what catches.
  defp authorized?(row), do: match?({:ok, _track, _project}, access(row))
end

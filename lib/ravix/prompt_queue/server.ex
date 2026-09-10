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

  Recovery (`Ravix.PromptQueue.recover/0`) runs at the start of the first
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
  alias Ravix.Fountain
  alias Ravix.Fountain.{Client, Error}
  alias Ravix.Hub
  alias Ravix.Projects.{Project, ProjectMember}
  alias Ravix.PromptQueue
  alias Ravix.PromptQueue.Item
  alias Ravix.Repo
  alias Ravix.Tracks.{Track, TrackMember, Transcript}

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
    # Every sweep, not once at boot. A claim can outlive the task holding it
    # -- killed for running long, or lost between the POST and the status
    # write -- and `:sending` is refused by both `cancel/3` and `retry/3`, so
    # nothing else would ever take it back. `PromptQueue.recover/0` only
    # reclaims claims older than `claim_timeout_ms/0`, so a task that is still
    # working is left alone.
    PromptQueue.recover()
    client = Fountain.client()

    if Client.configured?(client), do: deliver_heads(client)
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
    |> Task.Supervisor.async_stream_nolink(PromptQueue.heads(), &deliver(client, &1),
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
    cond do
      not authorized?(row) -> cancel(row)
      row.status != :queued -> :held
      true -> deliver_queued(client, row)
    end
  end

  defp deliver_queued(client, row) do
    # ownership: `authorized?/1` below ran first and put the row's sender
    # through `Access.track_access/2`. These read what to send it to.
    track = Repo.get!(Track, row.track_id)
    project = Repo.get!(Project, track.project_id)

    case readiness(client, track, project) do
      :ready -> claim_and_send(client, row, track, project)
      :busy -> :waiting
      {:ended, message} -> PromptQueue.set_status(row.id, :failed, message)
      :unavailable -> hold(row)
    end
  end

  # Nothing has been sent yet at this point. A read or credential refresh
  # that failed can safely retry on the next sweep.
  defp readiness(client, track, project) do
    case Fountain.get_conversation(client, track.conversation_id) do
      {:ok, %{"status" => status}} when status in ["running", "pending"] ->
        :busy

      {:ok, %{"status" => status} = conversation} when status in ["failed", "terminated"] ->
        {:ended, ended_message(client, track, conversation)}

      {:ok, _conversation} ->
        machine_readiness(client, project)

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
    if conversation["turn_count"] == 0 do
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
         %{} = event <- Enum.find(Enum.reverse(events), &failed_stage?/1) do
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

  defp failed_stage?(event),
    do: event["kind"] == "stage" and event["state"] == "failed"

  defp machine_readiness(client, project) do
    case Ravix.Projects.prepare_machine(project, client) do
      :ok -> :ready
      {:error, _reason} -> :unavailable
    end
  end

  defp hold(row) do
    case PromptQueue.get(row.id) do
      %Item{status: :queued} -> PromptQueue.set_status(row.id, :queued, @waiting)
      _ -> :ok
    end
  end

  # Membership and cancellation may change during the network calls above.
  defp claim_and_send(client, row, track, project) do
    cond do
      not authorized?(row) -> cancel(row)
      not PromptQueue.claim(row.id) -> :lost_claim
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

  defp post(client, row, track, project) do
    payload = row.id |> PromptQueue.get() |> Map.fetch!(:payload) |> Jason.decode!()
    instructions = Ravix.Previews.prepare_agent_preview(row)

    if authorized?(row) do
      text = compose(instructions, authored(row, track, project, payload["prompt"] || ""))
      Fountain.prompt(client, track.conversation_id, text, payload["images"] || [])
    else
      :revoked
    end
  end

  defp settle(:ok, row, track, project) do
    PromptQueue.mark_delivered(row.id)
    Hub.publish(project.id, :turn, track_id: track.id)
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
      Error.busy?(error) -> PromptQueue.set_status(row.id, :queued)
      Error.rejected?(error) -> PromptQueue.set_status(row.id, :failed, @refused)
      true -> PromptQueue.set_status(row.id, :unconfirmed, @unconfirmed)
    end
  end

  defp settle({:error, _reason}, row, _track, _project),
    do: PromptQueue.set_status(row.id, :unconfirmed, @unconfirmed)

  defp cancel(row), do: PromptQueue.set_status(row.id, :cancelled)

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
  # a conversation to deliver into.
  defp authorized?(row) do
    # ownership: this *is* the door. A queued prompt outlives the request that
    # made it, so who sent it is re-established here rather than trusted from
    # whenever it was accepted.
    with %User{} = user <- Ravix.Accounts.get_user(row.user_id),
         {:ok, %{track: track}} <- Access.track_access(user, row.track_id) do
      is_nil(track.closed_at) and is_binary(track.conversation_id) and track.conversation_id != ""
    else
      _ -> false
    end
  end
end

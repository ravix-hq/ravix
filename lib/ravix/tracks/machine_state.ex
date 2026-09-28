defmodule Ravix.Tracks.MachineState do
  @moduledoc """
  One word for what a track's machine is doing, and a sentence of detail.

  The header chip, the sidebar dot and the dock line all read this, so the
  three cannot disagree. It is pure: everything it reads is already on the
  presented `Ravix.Tracks.View` the page holds, including whether Fountain
  last said the dedicated sandbox was asleep (`Ravix.Tracks.Sleep` keeps that
  on the row). Nothing here asks Fountain, so drawing a rail of twenty tracks
  costs what it did before.

  Error is for a failure somebody must act on (setup failed, the machine
  failed); everything that recovers by itself or with the next message
  (starting, restarting, asleep, a failed turn) is said without alarm.

  The order of the clauses is the precedence. Closing outranks everything,
  since the machine is going away whatever else it was doing; an error
  outranks a lifecycle in progress; a rebuild or an opening outranks a turn,
  because a turn cannot run until the machine is up; and a turn outranks
  sleep, since a running turn is the machine awake.

  Asleep is said only on Fountain's word. For a dedicated track that is the
  stream or a refused read (`Ravix.Tracks.Sleep`). A shared track's machine
  is the project's, and the only word Ravix has of its sleep is setup parking
  on a refused read (`Ravix.Tracks.Setup`); otherwise it reads Idle rather
  than a guess.
  """

  alias Ravix.Tracks.View

  @type state :: :starting | :restarting | :working | :idle | :asleep | :closing | :error
  @type t :: %{state: state(), detail: String.t() | nil}

  @labels %{
    starting: "Starting",
    restarting: "Restarting",
    working: "Working",
    idle: "Idle",
    asleep: "Asleep",
    closing: "Closing",
    error: "Error"
  }

  @doc """
  The state of a presented track.

  Options: `running` (whether any of its threads is taking a turn; read off
  the view's status and threads by default, and passed by a page that holds
  fresher per-thread state from the stream) and `now` (for a retry
  countdown).
  """
  @spec of(View.t() | map(), keyword()) :: t()
  def of(track, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    running = Keyword.get_lazy(opts, :running, fn -> running?(track) end)
    derive(track, running, sandbox(track, running), now)
  end

  # `Ravix.Tracks.Sleep` records only a dedicated track's own sandbox. A turn
  # on a machine Fountain last said was asleep is the machine waking.
  defp sandbox(%{sandbox_layout: :dedicated, sandbox_suspended_at: %DateTime{}}, true),
    do: :resuming

  defp sandbox(%{sandbox_layout: :dedicated, sandbox_suspended_at: %DateTime{}}, _running),
    do: :suspended

  defp sandbox(_track, _running), do: nil

  defp derive(%{status: :closed}, _running, _sandbox, _now),
    do: %{state: :closing, detail: "Closed"}

  defp derive(%{sandbox_state: state} = track, _running, _sandbox, now)
       when state in [:closing, :terminated],
       do: %{state: :closing, detail: setup_label(track, now)}

  defp derive(%{status: :setup_failed} = track, _running, _sandbox, _now),
    do: %{state: :error, detail: Map.get(track, :setup_error) || "Setup failed"}

  defp derive(%{sandbox_state: :failed} = track, _running, _sandbox, _now),
    do: %{state: :error, detail: Map.get(track, :setup_error) || "This track's machine failed."}

  # Setup found the machine asleep and parked until somebody wants it: a
  # refused read said so, which is the machine's word rather than a guess.
  defp derive(
         %{setup_state: "running", setup_error_code: "sandbox_suspended"} = track,
         false,
         _sandbox,
         _now
       ),
       do: %{state: :asleep, detail: Map.get(track, :setup_error) || "Machine asleep"}

  defp derive(%{setup_state: "running", setup_error_code: "sandbox_suspended"}, true, _, _now),
    do: %{state: :starting, detail: "Waking the project's machine…"}

  defp derive(%{setup_state: setup} = track, _running, _sandbox, now) when setup != "ready",
    do: %{state: lifecycle(track), detail: setup_label(track, now)}

  defp derive(%{sandbox_state: :provisioning} = track, _running, _sandbox, now),
    do: %{state: lifecycle(track), detail: setup_label(track, now)}

  defp derive(_track, _running, :resuming, _now),
    do: %{state: :starting, detail: "Waking this track's machine…"}

  defp derive(_track, true, _sandbox, _now),
    do: %{state: :working, detail: "The agent is taking a turn."}

  # Setup reported ready but the opening turn has not: an older row that
  # `Ravix.Tracks.Setup` has yet to reconcile.
  defp derive(%{status: :opening}, _running, _sandbox, _now),
    do: %{state: :starting, detail: "Setting up…"}

  defp derive(_track, _running, :suspended, _now),
    do: %{state: :asleep, detail: "Your next message wakes it."}

  # A failed turn is not a failed machine, and the next message carries on,
  # so it is said rather than raised: Error is kept for what needs a hand.
  defp derive(%{status: :failed}, _running, _sandbox, _now),
    do: %{state: :idle, detail: "The last turn failed. Your next message carries on."}

  defp derive(_track, _running, _sandbox, _now), do: %{state: :idle, detail: nil}

  defp lifecycle(%{sandbox_action: :rebuild}), do: :restarting
  defp lifecycle(_track), do: :starting

  defp running?(track) do
    Map.get(track, :status) == :running or
      Enum.any?(Map.get(track, :threads) || [], &(Map.get(&1, :status) in [:running, :pending]))
  end

  @doc "The word the chip, the dot and the dock say for a state."
  @spec label(state()) :: String.t()
  def label(state), do: Map.fetch!(@labels, state)

  @doc """
  What a sidebar row marks: an unread reply wins over a machine with nothing
  to report (Idle or Asleep) and nothing else. Idle with nothing unread draws
  no dot.
  """
  @spec marker(t(), boolean()) :: state() | :unread | nil
  def marker(%{state: state}, true) when state in [:idle, :asleep], do: :unread
  def marker(%{state: :idle}, _unread), do: nil
  def marker(%{state: state}, _unread), do: state

  @doc """
  What setup is doing, in words. The chip's detail while a machine starts,
  and the setup panel's heading.
  """
  @spec setup_label(View.t() | map(), DateTime.t()) :: String.t()
  def setup_label(%{sandbox_state: :closing}, _now),
    do: "Closing… cleaning up this track's machine"

  def setup_label(%{setup_error_code: "sandbox_outcome_unknown"}, _now),
    do: "Checking this track's machine…"

  def setup_label(%{sandbox_stage: "creating"}, _now), do: "Creating this track's machine…"

  def setup_label(%{sandbox_stage: "cloning", repo_full_name: repo}, _now),
    do: "Cloning #{repo}…"

  def setup_label(%{sandbox_stage: "setup", setup_state: state}, _now) when state != "ready",
    do: "Running setup…"

  def setup_label(%{status: :closed}, _now), do: "Closed"
  def setup_label(%{setup_state: "failed"}, _now), do: "Setup failed"

  def setup_label(%{setup_state: "running", setup_error_code: "sandbox_suspended"}, _now),
    do: "Machine asleep"

  def setup_label(%{setup_state: "ready"}, _now), do: "Ready"

  def setup_label(%{setup_state: "retry", setup_error_code: code}, _now)
      when code in ["sandbox_at_capacity", "conversation_busy"], do: "Waiting for capacity"

  def setup_label(%{setup_state: "retry"} = track, now) do
    seconds =
      if track.setup_retry_at, do: max(0, DateTime.diff(track.setup_retry_at, now)), else: 0

    "Retrying (attempt #{min(track.setup_attempts + 1, 3)} of 3, next in #{seconds}s)"
  end

  def setup_label(_track, _now), do: "Setting up…"
end

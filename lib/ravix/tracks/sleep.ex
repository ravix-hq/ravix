defmodule Ravix.Tracks.Sleep do
  @moduledoc """
  Whether a dedicated track's sandbox is asleep, from what Fountain already
  tells Ravix.

  Fountain parks an idle sandbox and says so on the conversation's stream as a
  `sandbox`/`done` stage whose data is `{"event": "suspended", ...}`
  (`Ravix.Tracks.Transcript.Event.suspension/1`). It sends nothing on a
  resume, but a turn that starts is a machine that is awake. A file read
  refused with `409 sandbox_not_ready` and `status: "suspended"` says the
  same thing. Those three are the only inputs: nothing here asks Fountain,
  so the rail can show Asleep from its one query.

  What it cannot see is a sandbox parked while nobody followed its stream, or
  by Fountain's reaper, which parks without an event; that track reads Idle
  until a transcript read, a follower or a refused read catches up.
  """

  alias Ravix.Hub
  alias Ravix.Tracks.Store
  alias Ravix.Tracks.Transcript.Event

  @doc """
  What a run of events, oldest first, last said: `:suspended`, `:awake` once a
  turn started after it, or nil when none of them spoke to it.
  """
  @spec verdict([Event.t() | map()]) :: :suspended | :awake | nil
  def verdict(events) do
    Enum.reduce(events, nil, fn event, verdict ->
      event = Event.from(event)

      cond do
        Event.suspension(event) -> :suspended
        Event.starts_turn?(event) -> :awake
        true -> verdict
      end
    end)
  end

  @doc """
  Apply what a thread's conversation streamed, if it is still the thread's
  current conversation. The caller established access to the thread (a
  follower's subscribers, or a scoped transcript read).
  """
  @spec observe(String.t(), String.t() | nil, [Event.t() | map()]) :: :ok
  def observe(thread_id, conversation_id, events) do
    with verdict when not is_nil(verdict) <- verdict(events),
         %{conversation_id: ^conversation_id, track_id: track_id} when is_binary(conversation_id) <-
           Store.get_thread(thread_id) do
      record(track_id, verdict == :suspended)
    else
      _ -> :ok
    end
  end

  @doc """
  Record a dedicated track's sandbox as asleep or awake; publish only a
  change, as `:machine`, which readers answer from the database alone.
  """
  @spec record(String.t(), boolean()) :: :ok
  def record(track_id, suspended?) do
    case Store.set_sandbox_suspended(track_id, suspended?) do
      {project_id, ^track_id} -> Hub.publish(project_id, :machine, track_id: track_id)
      nil -> :ok
    end
  end
end

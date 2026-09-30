defmodule Ravix.Tracks.Titling do
  @moduledoc """
  Names a thread after what it is about, and a track after its first thread
  (RAV-48).

  Two sources, and no third. A runtime that titles its own session says so
  on the ACP stream (`session_info_update`, which the Claude adapter writes
  a second after its first reply, and Codex writes too); that title is
  preferred, because the runtime has read the whole exchange. Until one
  arrives, or when none ever does, the thread is called what
  `Ravix.Tracks.Title.from_prompt/1` reads out of its first prompt. Nothing
  here calls a model: the agent credential belongs to the conversation and
  is never read by Ravix (ADR 0005).

  A person's name always wins. `Ravix.Tracks.Store.rename_track/2` marks a
  rename `:manual`, which no automatic title replaces, and every write here
  is a compare-and-set against the title it read (`Store.auto_title/3`), so
  a rename landing while a title is being worked out is not overwritten
  either. A track is retitled only while it still carries the name it
  opened with or an earlier automatic title; its branch never moves.

  All of it runs under `Ravix.TaskSupervisor` (in the caller under test; see
  `Ravix.Config.background_titling?/0`), after the prompt was accepted, and
  fails silently: a missing title costs a label, and the
  person who sent the prompt is not told about it.
  """

  require Logger

  alias Ravix.Hub
  alias Ravix.Tracks.{Store, Thread, Title, Track}

  @doc """
  A prompt was accepted on `thread_id` as queue row `item_id`. If it is the
  thread's first, title the thread in the background. Answers at once.
  """
  @spec after_prompt(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def after_prompt(track_id, thread_id, item_id, prompt),
    do: background(fn -> from_prompt(track_id, thread_id, item_id, prompt) end)

  @doc """
  The runtime titled the session on `conversation_id`. Adopted, in the
  background, by a thread Ravix already titled automatically; one that still
  has its opening name was prompted before automatic titles existed, and
  keeps it.
  """
  @spec runtime_title(String.t(), String.t(), String.t()) :: :ok
  def runtime_title(track_id, conversation_id, title),
    do: background(fn -> from_runtime(track_id, conversation_id, title) end)

  @doc """
  `after_prompt/4`, in the calling process. Answers what happened, which is
  only ever logged.
  """
  @spec from_prompt(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | :stale | :skipped
  def from_prompt(track_id, thread_id, item_id, prompt) do
    with %Thread{title_source: nil} = thread <- Store.thread(track_id, thread_id),
         %Track{} = track <- Store.get_track(track_id),
         # ownership: the prompt on this row was accepted through
         # Access.thread_access/3 in `Ravix.Tracks`, which scheduled this.
         {^item_id, _prompt} <- Ravix.PromptQueue.Store.first_person_prompt(track_id, thread_id),
         title when is_binary(title) <- Title.from_prompt(prompt) do
      write(thread, track, title)
    else
      _ -> :skipped
    end
  end

  @doc "`runtime_title/3`, in the calling process."
  @spec from_runtime(String.t(), String.t(), String.t()) :: :ok | :stale | :skipped
  def from_runtime(track_id, conversation_id, title) do
    with %Thread{title_source: :auto} = thread <-
           Store.thread_by_conversation(track_id, conversation_id),
         %Track{} = track <- Store.get_track(track_id),
         title when is_binary(title) and title != thread.title <- Title.runtime(title) do
      write(thread, track, title)
    else
      _ -> :skipped
    end
  end

  defp write(thread, track, title) do
    with :ok <- Store.auto_title(thread, track, title) do
      Hub.publish(track.project_id, :tracks, track_id: track.id)
    end
  end

  defp background(fun) do
    if Ravix.Config.background_titling?() do
      {:ok, _pid} =
        Task.Supervisor.start_child(
          Ravix.TaskSupervisor,
          Ravix.Trace.link(fn -> quietly(fun) end)
        )
    else
      quietly(fun)
    end

    :ok
  end

  # Silent to the person, not to whoever runs the service.
  defp quietly(fun) do
    fun.()
  rescue
    error -> Logger.warning("ravix: automatic title dropped: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("ravix: automatic title dropped: #{inspect({kind, reason})}")
  end
end

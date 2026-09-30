defmodule Ravix.Tracks.Titling do
  @moduledoc """
  Names a thread after what it is about, and a track after its first thread
  (RAV-48).

  Two sources, and no third. A runtime that titles its own session says so
  on the ACP stream (`session_info_update`), and Fountain keeps that title
  on the conversation, redacted and tidied, marked `title_source: "harness"`
  (RAV-107). Ravix does not read the stream for it: it adopts the title from
  the conversation list it already fetches (`Ravix.MachineCache.conversations/3`),
  so a title given during a turn nobody was watching still arrives, and
  Fountain's parsing and redaction are the only ones. That title is
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
  `Ravix.Config.background_titling?/0`), after the prompt was accepted or
  the list was read, and fails silently: a missing title costs a label, and
  the person who sent the prompt is not told about it.

  Every instance reads its own list, so each may reach the same title. The
  compare-and-set lets one write it; the others read `:stale` and publish
  nothing, and a title already in place is skipped before any write.
  """

  require Logger

  alias Ravix.Fountain.Shapes.Conversation
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
  Fountain listed `conversations` for the project `project_id`. Each thread
  on one of them whose title is still automatic adopts the conversation's
  harness title, in the background. Answers at once, and costs no database
  read when no conversation carries a harness title.
  """
  @spec after_list(String.t(), [Conversation.t()]) :: :ok
  def after_list(project_id, conversations) do
    titles = harness_titles(conversations)

    if map_size(titles) == 0,
      do: :ok,
      else: background(fn -> from_fountain(project_id, titles) end)
  end

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

  @doc """
  `after_list/2`, in the calling process, given what `harness_titles/1`
  read off the list. Answers what happened to each thread, which is only
  ever logged.

  Idempotent: a thread already carrying the title is skipped without a
  write, and every write is `Store.auto_title/3`'s compare-and-set, so two
  instances reading the same list write it once and publish once.
  """
  @spec from_fountain(String.t(), %{String.t() => {String.t(), String.t() | nil}}) ::
          [:ok | :stale | :skipped]
  def from_fountain(project_id, titles) do
    project_id
    |> Store.auto_titled_threads(Map.keys(titles))
    |> Enum.map(fn {thread, track} ->
      {title, source} = Map.fetch!(titles, thread.conversation_id)
      adopt(thread, track, Title.runtime(title), source)
    end)
  end

  @doc """
  The harness titles on a conversation list, by conversation id, each with
  the `title_source` Fountain gave (nil when it gave none).

  A title is the harness's when Fountain says so. A Fountain that does not
  send `title_source` still sends `title`, and then a non-blank one is taken
  for the harness's; `adopt/4` refuses the one case where that is known to
  be wrong. A `"user"` title is the conversation owner's, set in Fountain,
  and is not the harness's.
  """
  @spec harness_titles([Conversation.t()]) :: %{String.t() => {String.t(), String.t() | nil}}
  def harness_titles(conversations) do
    for %Conversation{id: id, title: title, title_source: source} <- conversations,
        is_binary(id) and is_binary(title) and String.trim(title) != "",
        source in ["harness", nil],
        into: %{},
        do: {id, {title, source}}
  end

  defp adopt(_thread, _track, nil, _source), do: :skipped
  defp adopt(%Thread{title: title}, _track, title, _source), do: :skipped

  # Until this release every conversation was opened with a title, which
  # Fountain keeps as its owner's and never lets the harness replace. For a
  # track's first thread that was the branch. Without `title_source` it
  # cannot be told from a harness title, and adopting it would undo the title
  # the first prompt gave.
  defp adopt(_thread, %Track{branch: branch}, branch, nil), do: :skipped

  defp adopt(thread, track, title, _source), do: write(thread, track, title)

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

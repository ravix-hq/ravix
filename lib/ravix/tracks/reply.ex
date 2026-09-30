defmodule Ravix.Tracks.Reply do
  @moduledoc """
  The opening of a thread's newest reply, kept on the thread row for the
  Inbox card (RAV-66).

  The transcript is Fountain's, and a card that read it would make the
  Inbox one provider round trip per track. So the excerpt is written where
  a turn's events are already in hand: when settlement classifies the turn
  (`Ravix.Tracks.Settlement.persist/4`), and when somebody reads the
  transcript. A reply that settled with nobody following it, before this
  existed or on a machine nobody watched, is filled in by `backfill/2` the
  first time an Inbox shows it: one newest page of events per thread, off
  the page's process, never on the read that listed it.

  The excerpt is plain text, not markdown: the reply's last text block,
  with fences, markers and emphasis removed, its first two lines, cut at
  200 characters. It is shown escaped like any other agent output.
  """

  alias Ravix.{Cluster, Fountain, Hub, Trace}
  alias Ravix.Tracks.{Store, Transcript}
  alias Ravix.Tracks.Transcript.{Block, Event}

  @length 200
  @lines 2
  # How many threads one listing may send to Fountain for a missing excerpt.
  @backfills 8
  @page 60

  @doc "The opening of the reply `blocks` fold into, or nil when it says nothing in text."
  @spec excerpt([Block.t()]) :: String.t() | nil
  def excerpt(blocks) do
    blocks
    |> Enum.flat_map(fn
      %Block.Text{body: body} when is_binary(body) -> [lines(body)]
      _block -> []
    end)
    |> Enum.reject(&(&1 == []))
    |> List.last()
    |> case do
      nil -> nil
      lines -> lines |> Enum.take(@lines) |> Enum.join(" ") |> bound()
    end
  end

  @fence ~r/^\s*(```|~~~)/
  @marker ~r/^\s*(#+|>+|[-*+]|\d+[.)])\s+/
  @link ~r/!?\[([^\]]*)\]\([^)]*\)/
  @emphasis ~r/(\*\*|__|`)/
  @rule ~r/^\s*([-*_]\s*){3,}$/

  defp lines(body) do
    body
    |> String.split(~r/\R/)
    |> Enum.reduce({[], false}, fn line, {kept, fenced?} ->
      cond do
        Regex.match?(@fence, line) -> {kept, not fenced?}
        fenced? -> {kept, fenced?}
        true -> {[plain(line) | kept], fenced?}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp plain(line) do
    if Regex.match?(@rule, line) do
      ""
    else
      line
      |> String.replace(@marker, "")
      |> String.replace(@link, "\\1")
      |> String.replace(@emphasis, "")
      |> String.split()
      |> Enum.join(" ")
    end
  end

  defp bound(text) do
    if String.length(text) <= @length,
      do: text,
      else: String.slice(text, 0, @length - 1) |> String.trim_trailing() |> Kernel.<>("…")
  end

  @doc """
  Keep the excerpt of a settled turn, given its events in any order.
  A no-op when the thread already holds a newer reply.
  """
  @spec record(String.t(), [map() | Event.t()], String.t() | nil) :: :ok
  def record(conversation_id, events, runtime) do
    events = Enum.map(events, &Event.from/1)

    case settled_at(events) do
      nil -> :ok
      at -> put(conversation_id, excerpt(Transcript.blocks_for_turn(events, runtime)), at)
    end
  end

  @doc """
  Keep the excerpt of the newest settled turn on a transcript page already
  read, in the background. For a reply that settled before anybody kept one.
  """
  @spec note(Transcript.Page.t(), String.t()) :: :ok
  def note(%{turns: turns}, conversation_id) do
    turns
    |> Enum.filter(&(&1.settled? and &1.conversation_id == conversation_id))
    |> List.last()
    |> keep_later()
  end

  defp keep_later(nil), do: :ok

  defp keep_later(turn) do
    case settled_at(turn.events) do
      nil ->
        :ok

      at ->
        excerpt = excerpt(turn.blocks)
        work = Trace.link(fn -> put(turn.conversation_id, excerpt, at) end)
        Task.Supervisor.start_child(Ravix.TaskSupervisor, work)
        :ok
    end
  end

  @doc """
  Fill in the excerpt of each thread view (`Ravix.Tracks.list/3`'s
  `threads`) that `stale?/1` says needs one: one newest page of its
  conversation's events, at most eight threads per call, in parallel and
  bounded, one fill per thread in the cluster at a time. The caller waits,
  so it runs this off any page's process, and has admitted the threads.

  One attempt per reply. A conversation Fountain cannot answer for is kept
  as checked with no excerpt, and its card says so generically; its next
  reply is asked about again, and reading the transcript fills it in.
  """
  @spec backfill([map()], keyword()) :: :ok
  def backfill(threads, opts \\ []) do
    Ravix.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      threads |> Enum.filter(&stale?/1) |> Enum.take(@backfills),
      Trace.link_each(&fill(&1, opts)),
      max_concurrency: @backfills,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  @doc """
  Whether a settled thread's kept reply predates its conversation's last
  activity. A running turn is not asked about: settlement will keep it.
  """
  @spec stale?(map()) :: boolean()
  def stale?(%{status: status, last_active_at: %DateTime{} = active, reply_at: kept})
      when status in [:ready, :failed],
      do: is_nil(kept) or DateTime.before?(kept, active)

  def stale?(_thread), do: false

  defp fill(thread, opts) do
    name = Cluster.name(:reply_backfill, thread.id)

    # ownership: backfill/2's caller admitted this thread; its own row says
    # whether another fill or settlement kept the reply since it was listed.
    with :yes <- :global.register_name(name, self()) do
      try do
        if current?(Store.get_thread(thread.id), thread.last_active_at),
          do: :ok,
          else: Trace.span("transcript.reply_backfill", %{}, fn -> fetch(thread, opts) end)
      after
        :global.unregister_name(name)
      end
    end
  end

  defp current?(%{reply_at: %DateTime{} = kept}, active), do: not DateTime.before?(kept, active)
  defp current?(_row, _active), do: false

  defp fetch(%{conversation_id: id, last_active_at: active, runtime: runtime}, opts) do
    result =
      with {:ok, client} <- Keyword.get_lazy(opts, :client, &Ravix.Providers.fountain/0),
           {:ok, page} <-
             Fountain.events_page(client, id, order: :desc, whole_turns: true, limit: @page) do
        events = if page.window, do: Enum.reverse(page.events), else: page.events
        {:ok, Transcript.page(events, runtime, %{}).turns |> Enum.filter(& &1.settled?)}
      end

    # Kept as of the conversation's last activity rather than the settling
    # event, so the next Inbox finds the thread current and asks nothing.
    case result do
      {:ok, [_ | _] = settled} ->
        turn = List.last(settled)
        put(id, excerpt(turn.blocks), latest(settled_at(turn.events), active))

      _nothing ->
        put(id, nil, active)
    end
  end

  defp latest(nil, at), do: at
  defp latest(at, other), do: if(DateTime.after?(at, other), do: at, else: other)

  defp put(conversation_id, excerpt, at) do
    # ownership: settlement, an Access.thread_access transcript read or an
    # Access.open_tracks listing selected this conversation.
    case Store.put_reply(conversation_id, excerpt, at) do
      nil -> :ok
      project_id -> Hub.publish(project_id, :reply)
    end
  end

  # When the turn settled: its settling event's time, or its newest event's.
  defp settled_at(events) do
    events = Enum.sort_by(events, & &1.ts, :desc)
    event = Enum.find(events, &Event.settles?/1) || List.first(events)

    with %Event{ts: ts} when is_binary(ts) <- event,
         {:ok, at, _offset} <- DateTime.from_iso8601(ts) do
      at
    else
      _ -> nil
    end
  end
end

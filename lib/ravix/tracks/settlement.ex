defmodule Ravix.Tracks.Settlement do
  @moduledoc "Durable settlement classification, with supervised catch-up for previously unwatched turns."
  alias Ravix.{Cluster, Fountain, Hub, Trace}
  alias Ravix.Tracks.{AgentFailure, Billing, Reply, Store, Transcript}
  alias Ravix.Tracks.Transcript.Event

  @doc "Schedule missing settled turns without making the reader wait for classification."
  def enqueue(page, classified, binding) do
    Reply.note(page, List.last(binding.conversation_ids))

    Enum.each(page.turns, fn turn ->
      key = {turn.conversation_id, turn.id}

      if turn.settled? and turn.conversation_id in binding.conversation_ids and
           not MapSet.member?(classified, key),
         do: enqueue_turn(turn, binding)
    end)
  end

  # The most pages one scan reads back; an older remainder waits for the next open.
  @scan_pages 20

  @doc """
  Classify the settled turns on a page read newest first, then page back in
  the background only until a settled turn that is already classified.

  Classification is durable, so a classified turn marks where an earlier
  open got to. Steady state reads no further page; the first open of an old
  conversation walks back once, at most `@scan_pages` pages, off the read
  path. One walk per conversation runs at a time, and the per-turn
  registration deduplicates the classifications themselves.
  """
  def scan(client, history, events, runtime, binding) do
    Task.Supervisor.start_child(
      Ravix.TaskSupervisor,
      Trace.link(fn -> run_scan(client, history, events, runtime, binding) end)
    )

    :ok
  end

  defp run_scan(client, history, events, runtime, binding) do
    id = history.conversation_id

    Trace.span("transcript.classification_scan", %{"ravix.event_count" => length(events)}, fn ->
      # ownership: Access.thread_access authorized the page that scheduled this task.
      classified = Store.turn_classifications([id]).classified

      with :continue <- classify_page(events, id, classified, runtime, binding),
           true <- is_integer(history.before),
           do: walk_once(client, history, classified, runtime, binding)
    end)
  end

  # A lock rather than a name: `:global` gives a process one name, and this
  # one takes each turn's `:settlement` name as it classifies it.
  defp walk_once(client, history, classified, runtime, binding) do
    lock = {Cluster.name(:settlement_scan, history.conversation_id), self()}
    nodes = [node() | Node.list()]

    if :global.set_lock(lock, nodes, 0) do
      try do
        walk(client, history, classified, runtime, binding, 0)
      after
        :global.del_lock(lock, nodes)
      end
    end
  end

  defp walk(client, %{before: before} = history, classified, runtime, binding, pages)
       when is_integer(before) and pages < @scan_pages do
    case Transcript.History.read(client, history, :scan) do
      {:ok, events, history, stats} ->
        pages = pages + stats.pages
        Trace.annotate(%{"ravix.event_pages" => pages})

        if classify_page(events, history.conversation_id, classified, runtime, binding) ==
             :continue,
           do: walk(client, history, classified, runtime, binding, pages)

      {:error, _reason} ->
        :ok
    end
  end

  defp walk(_client, _history, _classified, _runtime, _binding, _pages), do: :ok

  defp classify_page(events, conversation_id, classified, runtime, binding) do
    settled = for turn <- Transcript.page(events, runtime, %{}).turns, turn.settled?, do: turn

    {known, unknown} =
      Enum.split_with(settled, &MapSet.member?(classified, {conversation_id, &1.id}))

    for turn <- unknown do
      key = conversation_id <> "/" <> turn.id
      background(key, conversation_id, turn.id, turn.events, runtime, binding)
    end

    cond do
      known != [] -> :done
      unknown != [] -> :continue
      # Nothing settled here (a running turn over the limit): an earlier open
      # already classified what is behind it, unless nothing ever was.
      true -> if first_scan?(classified, conversation_id), do: :continue, else: :done
    end
  end

  defp first_scan?(classified, conversation_id),
    do: not Enum.any?(classified, &match?({^conversation_id, _}, &1))

  @doc "Classify every settled turn in a fetched snapshot, including turns outside the visible page."
  def enqueue_log(log, conversation_id, runtime, binding) do
    if Enum.any?(log, &(Event.from(&1) |> Event.settles?())) do
      Task.Supervisor.start_child(
        Ravix.TaskSupervisor,
        Trace.link(fn -> classify_log(log, conversation_id, runtime, binding) end)
      )
    end

    :ok
  end

  defp classify_log(log, conversation_id, runtime, binding) do
    Trace.span("transcript.classification_scan", %{"ravix.event_count" => length(log)}, fn ->
      # ownership: Access.thread_access authorized the snapshot that scheduled this task.
      classified = Store.turn_classifications([conversation_id]).classified
      page = Transcript.page(log, runtime, %{})

      for turn <- page.turns,
          turn.settled?,
          not MapSet.member?(classified, {conversation_id, turn.id}) do
        key = conversation_id <> "/" <> turn.id
        # The same per-turn global registration and durable transaction as live
        # settlement deduplicate overlapping snapshots and concurrent readers.
        background(key, conversation_id, turn.id, turn.events, runtime, binding)
      end
    end)
  end

  defp enqueue_turn(turn, binding) do
    key = turn.conversation_id <> "/" <> turn.id

    if is_nil(Cluster.whereis(:settlement, key)) do
      # Copy only this turn's evidence, not its fold or the whole page. A racing
      # reader can start a task too, but only one registers and does any work.
      events = turn.events
      conversation_id = turn.conversation_id
      turn_id = turn.id
      runtime = turn.runtime

      Task.Supervisor.start_child(
        Ravix.TaskSupervisor,
        Trace.link(fn ->
          background(key, conversation_id, turn_id, events, runtime, binding)
        end)
      )
    end
  end

  defp background(key, conversation_id, turn_id, events, runtime, binding) do
    name = Cluster.name(:settlement, key)

    if :global.register_name(name, self()) == :yes do
      try do
        Trace.span("transcript.background", %{"ravix.event_count" => length(events)}, fn ->
          result = persist(conversation_id, turn_id, Enum.reverse(events), runtime)
          publish_correction(result, conversation_id, turn_id, binding)
        end)
      after
        :global.unregister_name(name)
      end
    end
  end

  defp publish_correction({:ok, _}, conversation_id, turn_id, binding) do
    # ownership: Access.thread_access authorized the read that scheduled this evidence.
    if Store.turn_failure(conversation_id, turn_id) do
      Hub.publish(binding.project_id, :turn,
        track_id: binding.track_id,
        thread_id: binding.thread_id
      )
    end
  end

  defp publish_correction(_error, _conversation_id, _turn_id, _binding), do: :ok

  def record(client, thread_id, conversation_id, %Event{turn_id: "pending"} = event) do
    if Event.suspension(event),
      do: record_bound(client, thread_id, conversation_id, event),
      else: :ok
  end

  def record(client, thread_id, conversation_id, event),
    do: record_bound(client, thread_id, conversation_id, event)

  defp record_bound(client, thread_id, conversation_id, event) do
    # ownership: Follower subscribers established Access.thread_access for this thread.
    case Store.get_thread(thread_id) do
      %{conversation_id: ^conversation_id} = thread ->
        # ownership: record/4 verified the follower's current thread binding.
        classify(client, conversation_id, event, Store.transcript_runtime(thread))

      _ ->
        :ok
    end
  end

  @doc "Operator-only, idempotent historical backfill; never called by a transcript read."
  def backfill(thread_id, client \\ Fountain.client()) do
    # ownership: this is the explicit maintenance command's thread ID, not a web door.
    case Store.get_thread(thread_id) do
      nil ->
        {:error, :not_found}

      thread ->
        # ownership: the operator selected this thread for historical classification.
        runtime = Store.transcript_runtime(thread)
        ids = Enum.reject(thread.previous_conversation_ids ++ [thread.conversation_id], &is_nil/1)

        Enum.reduce_while(ids, :ok, fn id, :ok ->
          continue_backfill(backfill_conversation(client, id, runtime))
        end)
    end
  end

  defp backfill_conversation(client, id, runtime) do
    with {:ok, log} <- Fountain.events(client, id, []) do
      page = Transcript.page(log, runtime, %{})

      Enum.reduce_while(page.turns, :ok, fn turn, :ok ->
        continue_backfill(backfill_turn(id, turn, runtime))
      end)
    end
  end

  defp backfill_turn(id, %{settled?: true} = turn, runtime),
    do: persist(id, turn.id, Enum.reverse(turn.events), runtime)

  defp backfill_turn(_id, _turn, _runtime), do: :ok

  defp continue_backfill({:error, _} = error), do: {:halt, error}
  defp continue_backfill(_result), do: {:cont, :ok}

  # A sandbox-wide suspension belongs only to the immediately preceding open
  # turn, exactly as in the transcript. A sleep between turns records nothing.
  defp classify(client, conversation_id, %Event{turn_id: "pending"} = event, runtime) do
    with {:ok, log} <- Fountain.events(client, conversation_id, prompts: true) do
      page = Transcript.page(Enum.uniq_by(log ++ [event], &Event.from(&1).id), runtime, %{})

      case Enum.find(page.turns, fn turn -> Enum.any?(turn.events, &(&1.id == event.id)) end) do
        nil -> :ok
        turn -> persist(conversation_id, turn.id, Enum.reverse(turn.events), runtime)
      end
    end
  end

  defp classify(client, conversation_id, event, runtime) do
    # ownership: no door; record/4 verified the authorized follower's current binding.
    if Store.turn_classified?(conversation_id, event.turn_id) do
      {:ok, :already_classified}
    else
      # Fetch outside the DB transaction. The lock in persist/4 serializes only
      # classification and its writes, never provider latency.
      with {:ok, log} <- Fountain.events(client, conversation_id, prompts: true) do
        events = Enum.filter(log, &(Event.from(&1).turn_id == event.turn_id))
        events = Enum.uniq_by(events ++ [event], &Event.from(&1).id)
        persist(conversation_id, event.turn_id, events, runtime)
      end
    end
  end

  defp persist(conversation_id, turn_id, events, runtime) do
    # ownership: the current follower binding or explicit maintenance command selected this turn.
    result = Store.classify_turn_once(conversation_id, turn_id, fn -> detect(events, runtime) end)

    # Once per turn, after the classification that claimed it committed: a
    # creator-billed track's harness pauses on a turn its payer's credential
    # failed (`Ravix.Tracks.Billing.observe_turn/5`).
    with {:ok, %Ravix.Tracks.TurnFailure{}} <- result,
         do: observe_billing(conversation_id, events, runtime)

    # The turn's events are in hand: keep the opening of its reply for the
    # Inbox (`Ravix.Tracks.Reply`), whoever classified it first.
    if match?({:ok, _}, result), do: Reply.record(conversation_id, events, runtime)

    result
  end

  defp observe_billing(conversation_id, events, runtime) do
    # ownership: no door; the Access.thread_access follower binding or authorized read
    # that scheduled this turn's classification chose the conversation.
    with %Ravix.Tracks.Track{billing_policy: :creator} = track <-
           Store.track_by_conversation(conversation_id),
         # ownership: no door; the project of the track the classification found above.
         %Ravix.Projects.Project{} = project <-
           Ravix.Projects.Store.for_track(
             Ravix.Projects.Store.get_project(track.project_id),
             track
           ) do
      Billing.observe_turn(track, project, runtime, events)
    end
  end

  defp detect(events, runtime) do
    Trace.span("transcript.failure_detection", %{"ravix.event_count" => length(events)}, fn ->
      blocks = Transcript.blocks_for_turn(events, runtime)
      {:ok, AgentFailure.detect(events, runtime, blocks)}
    end)
  end
end

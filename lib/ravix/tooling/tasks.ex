defmodule Ravix.Tooling.Tasks do
  @moduledoc "Durable delegated prompts. Completion comes only from the correlated Fountain turn."
  alias Ravix.Accounts.Access
  alias Ravix.{Fountain, PromptQueue, Tracks}
  alias Ravix.Tooling.{Authorization, Store, Task, TaskPage}
  alias Ravix.Tracks.AgentFailure
  alias Ravix.Tracks.Transcript
  alias Ravix.Tracks.Transcript.{Block, Event}

  @terminal ~w(TASK_STATE_COMPLETED TASK_STATE_FAILED TASK_STATE_CANCELED TASK_STATE_REJECTED)
  def topic(id), do: "tooling:task:" <> id
  defp publish(id), do: Phoenix.PubSub.broadcast(Ravix.PubSub, topic(id), {:tooling_task, id})

  def terminal?(task), do: task.state in @terminal

  def send(principal, track_id, prompt, request_id, thread_id \\ nil) do
    with {:ok, principal} <- Authorization.check(principal, "tracks:write"),
         {:ok, %{thread: thread}} <- Access.thread_access(principal.user, track_id, thread_id) do
      id = id(principal, request_id)

      fingerprint =
        if thread.id == track_id,
          do: digest({track_id, prompt}),
          else: digest({track_id, thread.id, prompt})

      result =
        Store.transaction(fn ->
          accept(principal, id, track_id, prompt, fingerprint, thread.id)
        end)

      Phoenix.PubSub.broadcast(Ravix.PubSub, "tooling:queue", {:tooling_queue, track_id})
      result
    end
  end

  defp accept(principal, id, track_id, prompt, fingerprint, thread_id) do
    # Queue acceptance and the task receipt share a transaction.
    case Store.task(id) do
      %Task{fingerprint: ^fingerprint} = task -> task
      %Task{} -> Store.rollback(conflict())
      nil -> enqueue(principal, id, track_id, prompt, fingerprint, thread_id)
    end
  end

  defp enqueue(principal, id, track_id, prompt, fingerprint, thread_id) do
    case Tracks.prompt(principal.user, track_id, %{
           "prompt" => prompt,
           "request_id" => id,
           "thread_id" => thread_id
         }) do
      {:ok, _} ->
        # The queue serializes on the track; re-read after it to resolve two
        # simultaneous retries before inserting the task's unique receipt.
        case Store.task(id) do
          nil ->
            Store.insert(%Task{
              id: id,
              user_id: principal.user.id,
              client_id: principal.grant.client_id,
              track_id: track_id,
              fingerprint: fingerprint
            })

          %Task{fingerprint: ^fingerprint} = task ->
            task

          _ ->
            Store.rollback(conflict())
        end

      {:error, reason} ->
        Store.rollback(reason)
    end
  end

  def get(principal, id) do
    with {:ok, principal} <- Authorization.check(principal, "tracks:read"),
         {:ok, task, access} <- accessible(principal, id),
         {:ok, _} <- refresh(task, access),
         {:ok, _} <- Authorization.check(principal, "tracks:read"),
         {:ok, current, _} <- accessible(principal, id) do
      {:ok, current}
    end
  end

  @doc "Authorize every task before subscribing or returning a multi-task snapshot."
  def observe(principal, ids) do
    with {:ok, principal} <- Authorization.check(principal, "tracks:read") do
      observe_rows(principal, ids)
    end
  end

  defp observe_rows(principal, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, rows} ->
      case accessible(principal, id) do
        {:ok, task, access} ->
          row = %{
            task: task,
            project_id: access.project.id,
            track_id: task.track_id,
            thread_id: access.thread.id,
            conversation_id: access.thread.conversation_id,
            access: access
          }

          {:cont, {:ok, rows ++ [row]}}

        error ->
          {:halt, error}
      end
    end)
  end

  @doc "Refresh a scoped set once per thread, sharing provider pages."
  def refresh_many(principal, ids) do
    with {:ok, rows} <- observe(principal, ids) do
      reconcile_rows(Enum.map(rows, &{&1.task, &1.access}))
    end
  end

  def cancel(principal, id) do
    with {:ok, principal} <- Authorization.check(principal, "tracks:cancel"),
         {:ok, task} <- actionable(principal, id),
         :ok <- PromptQueue.cancel(principal.user, task.track_id, task.id) do
      {:ok, Store.update(task, state: "TASK_STATE_CANCELED")}
    else
      {:error, {:conflict, "already_sending", _}} ->
        {:error,
         {:conflict, "task_not_cancelable",
          "Only queued, failed or unconfirmed prompts can be canceled; sending or delivered prompts cannot."}}

      error ->
        error
    end
  end

  def retry(principal, id) do
    with {:ok, principal} <- Authorization.check(principal, "tracks:write"),
         {:ok, task} <- actionable(principal, id),
         :ok <- PromptQueue.retry(principal.user, task.track_id, task.id) do
      {:ok,
       Store.update(task, state: "TASK_STATE_SUBMITTED", turn_id: nil, cursor: nil, result: "")}
    end
  end

  # Actions intentionally use the queue's sender-or-owner rule. Reading a
  # receipt and its reply remains restricted to the original OAuth client.
  defp actionable(principal, id) do
    with %Task{} = task <- Store.task(id),
         {:ok, _} <- PromptQueue.status(principal.user, task.track_id, id) do
      {:ok, task}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def list(principal, params) do
    with {:ok, principal} <- Authorization.check(principal, "tracks:read"),
         {:ok, opts} <- TaskPage.parse(params) do
      {rows, total} = Store.tasks(principal.user.id, principal.grant.client_id, opts)
      page = Enum.take(rows, opts.limit)
      visible = Enum.filter(page, &match?({:ok, _, _}, accessible(principal, &1.id)))

      tasks = Enum.map(visible, &list_view(&1, opts.artifacts))

      cursor =
        if length(rows) > opts.limit, do: TaskPage.cursor(List.last(page)), else: ""

      {:ok, %{tasks: tasks, nextPageToken: cursor, pageSize: opts.limit, totalSize: total}}
    end
  end

  defp list_view(task, true), do: present(task)
  defp list_view(task, false), do: Map.delete(present(task), :artifacts)

  defp accessible(principal, id) do
    user_id = principal.user.id
    client_id = principal.grant.client_id

    with %Task{user_id: ^user_id, client_id: ^client_id} = task <- Store.task(id),
         {:ok, queue} <- PromptQueue.status(principal.user, task.track_id, task.id),
         {:ok, access} <- Access.thread_access(principal.user, task.track_id, queue.thread_id) do
      {:ok, queue_view(task, queue, access.track), access}
    else
      _ -> {:error, :not_found}
    end
  end

  defp refresh(%Task{state: state} = task, _) when state in @terminal,
    do: {:ok, persist_queue(task)}

  defp refresh(%Task{queue_status: status} = task, access) when status in [:sent, :sending],
    do: reconcile(task, access)

  defp refresh(task, _access), do: {:ok, persist_queue(task)}

  defp queue_view(task, queue, track) do
    {state, message} =
      case queue.status do
        :cancelled ->
          {"TASK_STATE_CANCELED", nil}

        :failed ->
          {"TASK_STATE_FAILED",
           queue.error || "Prompt delivery failed. Retry or cancel this task."}

        :unconfirmed ->
          {"TASK_STATE_INPUT_REQUIRED",
           queue.error || "Delivery could not be confirmed. Check the transcript before retrying."}

        :queued ->
          {"TASK_STATE_SUBMITTED", blocked_message(queue)}

        _ ->
          {delivered_state(task), task.failure_message}
      end

    %{
      task
      | state: state,
        status_message: message,
        error_code: queue.error_code,
        # Setup is a track state, not a replacement for the provider failure code.
        setup_failed: match?(%{setup_state: "failed"}, track),
        queue_status: queue.status,
        blocked: not is_nil(queue.blocked_by)
    }
  end

  # Older versions persisted queue failure as terminal. A web retry may
  # resume delivery without touching that receipt; only a correlated turn
  # can keep it failed once the queue is sending or sent again.
  defp delivered_state(%{state: "TASK_STATE_FAILED", turn_id: nil}), do: "TASK_STATE_SUBMITTED"
  defp delivered_state(%{state: "TASK_STATE_INPUT_REQUIRED"}), do: "TASK_STATE_SUBMITTED"
  defp delivered_state(task), do: task.state

  defp blocked_message(%{blocked_by: %{id: id, status: status}}),
    do:
      "Waiting behind #{if status == :unconfirmed, do: "an unconfirmed", else: "a failed"} prompt #{id}."

  defp blocked_message(queue), do: queue.error

  def held_or_terminal?(task),
    do: terminal?(task) or task.state == "TASK_STATE_INPUT_REQUIRED" or task.blocked

  def version(task), do: digest({task.state, task_message(task)})

  @doc false
  def reconcile_rows(rows) do
    rows
    |> Enum.group_by(fn {_task, access} -> access.thread.id end)
    |> Enum.reduce_while(:ok, fn {_id, group}, :ok ->
      case reconcile_group(group) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reconcile_group(rows) do
    rows =
      Enum.map(rows, fn {task, access} ->
        current = persist_queue(task)
        current = %{current | reconciled_at: Store.record_reconciliation(task.id)}

        if current.state != task.state,
          do: publish(task.id)

        {current, access}
      end)

    active =
      Enum.filter(rows, fn {task, _} ->
        not terminal?(task) and task.queue_status in [:sent, :sending]
      end)

    case active do
      [] ->
        :ok

      [{_, access} | _] ->
        with {:ok, client} <- Ravix.Providers.fountain(),
             {:ok, turns} <- Fountain.turns(client, access.thread.conversation_id) do
          reconcile_turns(active, client, turns)
        end
    end
  end

  defp reconcile_turns(rows, client, turns) do
    Enum.reduce_while(rows, {:ok, %{}}, fn {task, access}, {:ok, pages} ->
      result =
        case Enum.find(turns, &(&1.client_request_id == task.id)) do
          nil -> {:ok, pages}
          turn -> collect(task, access, client, turn, pages)
        end

      case result do
        {:ok, pages} -> {:cont, {:ok, pages}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp persist_queue(task) do
    {:ok, current} =
      Store.transaction(fn ->
        # ownership: no door for internal receipt reconciliation; the queue owns delivery
        # state, and public reads still pass accessible/2's principal/client door.
        {:ok, queue} = Ravix.PromptQueue.Store.lock_row(task.id, task.track_id)
        current = Store.lock_task(task.id)
        queue = Map.put(queue, :blocked_by, Ravix.PromptQueue.Store.held_before(queue))
        # The same receipt door: setup state only shapes MCP recovery guidance.
        track = Ravix.Tracks.Store.get_track(task.track_id)
        view = queue_view(current, queue, track)
        if view.state != current.state, do: Store.update(current, state: view.state)
        view
      end)

    current
  end

  defp reconcile(task, access) do
    with :ok <- reconcile_rows([{task, access}]), do: {:ok, Store.task(task.id)}
  end

  defp collect(task, access, client, turn, pages) do
    finished = turn_state(turn.status) in @terminal
    cursor = if finished, do: nil, else: task.cursor

    with {:ok, page, pages} <-
           collect_pages(
             client,
             access.thread.conversation_id,
             turn,
             cursor,
             %{events: [], seen: not is_nil(cursor) and task.turn_id == turn.id},
             pages
           ),
         runtime <- access.thread.runtime || access.project.runtime,
         text <- reply(page.events, turn.id, runtime) do
      blocks = Transcript.blocks_for_turn(page.events, runtime)

      failure =
        if finished,
          do: AgentFailure.detect(page.events, runtime, blocks),
          else: AgentFailure.suspension(page.events)

      {:ok, saved} =
        Store.transaction(fn -> persist_outcome(task, access, turn, page, text, failure) end)

      if {saved.state, saved.result, saved.cursor} != {task.state, task.result, task.cursor},
        do: publish(task.id)

      {:ok, pages}
    end
  end

  defp persist_outcome(task, access, turn, page, text, failure) do
    if failure do
      # ownership: no door for bookkeeping; reconciliation correlates an existing receipt's thread and turn.
      Ravix.Tracks.Store.record_turn_failure(
        access.thread.conversation_id,
        turn.id,
        "turn",
        failure
      )
    end

    save_page(task, turn, page, text, failure)
  end

  # Cache provider pages across receipts belonging to this thread.
  defp collect_pages(client, conversation_id, turn, cursor, acc, pages) do
    with {:ok, page} <- cached_page(pages, cursor, client, conversation_id) do
      pages = Map.put(pages, cursor, page)
      {events, seen, past} = turn_window(page.events, turn.id, acc.seen)
      acc = %{events: [events | acc.events], seen: seen}

      cond do
        not page.has_more or past or turn_state(turn.status) not in @terminal ->
          {:ok, %{page | events: acc.events |> Enum.reverse() |> List.flatten()}, pages}

        is_nil(page.next_cursor) or (not is_nil(cursor) and page.next_cursor <= cursor) ->
          {:error,
           %Fountain.Error{
             status: 0,
             code: "pagination_stalled",
             message: "Fountain event pagination did not advance",
             kind: :api
           }}

        true ->
          collect_pages(client, conversation_id, turn, page.next_cursor, acc, pages)
      end
    end
  end

  defp cached_page(pages, cursor, client, conversation_id) do
    case Map.fetch(pages, cursor) do
      {:ok, page} -> {:ok, page}
      :error -> Fountain.events_page(client, conversation_id, after: cursor, limit: 100)
    end
  end

  defp turn_window(events, turn_id, seen) do
    {events, seen, past} =
      Enum.reduce_while(events, {[], seen, false}, fn event, {events, seen, false} ->
        case event["turn_id"] do
          ^turn_id ->
            {:cont, {[event | events], true, false}}

          nil ->
            {:cont, {include_suspension(event, events, turn_id, seen), seen, false}}

          _ when seen ->
            {:halt, {events, seen, true}}

          _ ->
            {:cont, {events, seen, false}}
        end
      end)

    {Enum.reverse(events), seen, past}
  end

  defp include_suspension(event, events, turn_id, seen) do
    if seen and Event.suspension(Event.from(event)),
      do: [Map.put(event, "turn_id", turn_id) | events],
      else: events
  end

  defp save_page(task, turn, page, text, failure) do
    # ownership: no door for bookkeeping of existing receipts; lock queue before receipt to fence late reads.
    {:ok, queue} = Ravix.PromptQueue.Store.lock_row(task.id, task.track_id)
    current = Store.lock_task(task.id)

    if stale_page?(task, current, queue) do
      current
    else
      state = if failure, do: "TASK_STATE_FAILED", else: turn_state(turn.status)
      result = if state in @terminal, do: text, else: current.result <> text

      Store.update(current,
        state: state,
        turn_id: turn.id,
        cursor: page.next_cursor || current.cursor,
        result: String.slice(if(failure, do: failure.reason, else: result), 0, 64_000),
        failure_code: failure && failure.code,
        failure_message: failure && failure.reason
      )
    end
  end

  defp stale_page?(task, current, queue) do
    queue.status not in [:sent, :sending] or current.cursor != task.cursor or
      terminal?(%{current | state: delivered_state(current)})
  end

  defp reply(events, turn_id, runtime) do
    events
    |> Enum.filter(&(&1["turn_id"] == turn_id))
    |> Transcript.page(runtime)
    |> Map.fetch!(:turns)
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map_join(fn
      %Block.Text{body: body} -> body
      _ -> ""
    end)
  end

  defp turn_state(status) when status in ["ended", "completed", "done"],
    do: "TASK_STATE_COMPLETED"

  defp turn_state(status) when status in ["failed", "interrupted", "suspended"],
    do: "TASK_STATE_FAILED"

  defp turn_state(status) when status in ["canceled", "cancelled"], do: "TASK_STATE_CANCELED"
  defp turn_state(_), do: "TASK_STATE_WORKING"

  def present(task) do
    %{
      id: task.id,
      contextId: task.track_id,
      status: status(task),
      metadata: %{ravix: %{status_version: version(task)}},
      artifacts: [
        %{artifactId: task.id <> "-reply", name: "Agent reply", parts: [%{text: task.result}]}
      ]
    }
  end

  defp status(task) do
    status = %{
      state: task.state,
      timestamp: DateTime.to_iso8601(task.updated_at)
    }

    if message = task_message(task) do
      Map.put(status, :message, %{
        role: "ROLE_AGENT",
        messageId: version(task),
        parts: [%{text: message}]
      })
    else
      status
    end
  end

  defp task_message(%{queue_status: :failed, setup_failed: true} = task) do
    "#{task.status_message} Call retry_setup with track_id #{task.track_id}, then after setup succeeds call retry_task with task_id #{task.id}."
  end

  defp task_message(task), do: task.status_message

  def id(principal, request_id),
    do: digest({principal.user.id, principal.grant.client_id, request_id})

  def digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp conflict,
    do: {:conflict, "request_id_used", "This request ID already names different work."}
end

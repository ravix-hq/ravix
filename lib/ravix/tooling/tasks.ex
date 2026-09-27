defmodule Ravix.Tooling.Tasks do
  @moduledoc "Durable delegated prompts. Completion comes only from the correlated Fountain turn."
  alias Ravix.Accounts.Access
  alias Ravix.{Fountain, PromptQueue, Tracks}
  alias Ravix.Tooling.{Authorization, Store, Task, TaskPage}
  alias Ravix.Tracks.Transcript
  alias Ravix.Tracks.Transcript.Block

  @terminal ~w(TASK_STATE_COMPLETED TASK_STATE_FAILED TASK_STATE_CANCELED TASK_STATE_REJECTED)
  def terminal?(task), do: task.state in @terminal

  def send(principal, track_id, prompt, request_id, thread_id \\ nil) do
    with {:ok, principal} <- Authorization.check(principal, "tracks:write"),
         {:ok, %{thread: thread}} <- Access.thread_access(principal.user, track_id, thread_id) do
      id = id(principal, request_id)

      fingerprint =
        if thread.id == track_id,
          do: digest({track_id, prompt}),
          else: digest({track_id, thread.id, prompt})

      Store.transaction(fn -> accept(principal, id, track_id, prompt, fingerprint, thread.id) end)
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
            conversation_id: access.thread.conversation_id
          }

          {:cont, {:ok, rows ++ [row]}}

        error ->
          {:halt, error}
      end
    end)
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
      {:ok, queue_view(task, queue), access}
    else
      _ -> {:error, :not_found}
    end
  end

  defp refresh(%Task{state: state} = task, _) when state in @terminal, do: {:ok, task}

  defp refresh(%Task{queue_status: status} = task, access) when status in [:sent, :sending],
    do: reconcile(task, access)

  defp refresh(task, _access), do: {:ok, task}

  defp queue_view(task, queue) do
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
          {delivered_state(task), nil}
      end

    %{
      task
      | state: state,
        status_message: message,
        queue_status: queue.status,
        blocked: not is_nil(queue.blocked_by)
    }
  end

  # Older versions persisted queue failure as terminal. A web retry may
  # resume delivery without touching that receipt; only a correlated turn
  # can keep it failed once the queue is sending or sent again.
  defp delivered_state(%{state: "TASK_STATE_FAILED", turn_id: nil}), do: "TASK_STATE_SUBMITTED"
  defp delivered_state(task), do: task.state

  defp blocked_message(%{blocked_by: %{id: id, status: status}}),
    do:
      "Waiting behind #{if status == :unconfirmed, do: "an unconfirmed", else: "a failed"} prompt #{id}."

  defp blocked_message(queue), do: queue.error

  def held_or_terminal?(task),
    do: terminal?(task) or task.state == "TASK_STATE_INPUT_REQUIRED" or task.blocked

  def version(task), do: digest({task.state, task.status_message})

  defp reconcile(task, access) do
    with {:ok, client} <- Ravix.Providers.fountain(),
         {:ok, turns} <- Fountain.turns(client, access.thread.conversation_id) do
      case Enum.find(turns, &(&1.client_request_id == task.id)) do
        nil -> {:ok, task}
        turn -> collect(task, access, client, turn)
      end
    end
  end

  defp collect(task, access, client, turn) do
    finished = turn_state(turn.status) in @terminal
    # Rebuild a finished reply from its complete event window: ACP replies may
    # span pages, and a previous poll may already have consumed its last event.
    cursor = if finished, do: nil, else: task.cursor

    with {:ok, page} <-
           collect_pages(client, access.thread.conversation_id, turn, cursor, %{
             events: [],
             seen: false
           }),
         text <- reply(page.events, turn.id, access.thread.runtime || access.project.runtime) do
      Store.transaction(fn -> save_page(task, turn, page, text) end)
    end
  end

  defp collect_pages(client, conversation_id, turn, cursor, acc) do
    with {:ok, page} <- Fountain.events_page(client, conversation_id, after: cursor, limit: 100) do
      {events, seen, past} = turn_window(page.events, turn.id, acc.seen)
      acc = %{events: [events | acc.events], seen: seen}

      cond do
        not page.has_more or past or turn_state(turn.status) not in @terminal ->
          {:ok, %{page | events: acc.events |> Enum.reverse() |> List.flatten()}}

        is_nil(page.next_cursor) or (not is_nil(cursor) and page.next_cursor <= cursor) ->
          {:error,
           %Fountain.Error{
             status: 0,
             code: "pagination_stalled",
             message: "Fountain event pagination did not advance",
             kind: :api
           }}

        true ->
          collect_pages(client, conversation_id, turn, page.next_cursor, acc)
      end
    end
  end

  defp turn_window(events, turn_id, seen) do
    {events, seen, past} =
      Enum.reduce_while(events, {[], seen, false}, fn event, {events, seen, false} ->
        case event["turn_id"] do
          ^turn_id -> {:cont, {[event | events], true, false}}
          nil -> {:cont, {events, seen, false}}
          _ when seen -> {:halt, {events, seen, true}}
          _ -> {:cont, {events, seen, false}}
        end
      end)

    {Enum.reverse(events), seen, past}
  end

  defp save_page(task, turn, page, text) do
    current = Store.lock_task(task.id)

    if current.cursor != task.cursor or terminal?(%{current | state: delivered_state(current)}) do
      current
    else
      state = turn_state(turn.status)
      result = if state in @terminal, do: text, else: current.result <> text

      Store.update(current,
        state: state,
        turn_id: turn.id,
        cursor: page.next_cursor || current.cursor,
        result: String.slice(result, 0, 64_000)
      )
    end
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

  defp turn_state("failed"), do: "TASK_STATE_FAILED"
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

    if task.status_message do
      Map.put(status, :message, %{
        role: "ROLE_AGENT",
        messageId: version(task),
        parts: [%{text: task.status_message}]
      })
    else
      status
    end
  end

  def id(principal, request_id),
    do: digest({principal.user.id, principal.grant.client_id, request_id})

  def digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp conflict,
    do: {:conflict, "request_id_used", "This request ID already names different work."}
end

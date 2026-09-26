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
         {:ok, task} <- refresh(task, access),
         {:ok, _} <- Authorization.check(principal, "tracks:read"),
         {:ok, _, _} <- accessible(principal, id) do
      {:ok, task}
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
         {:ok, task, _} <- accessible(principal, id),
         :ok <- cancel_queue(principal, task) do
      {:ok, Store.update(task, state: "TASK_STATE_CANCELED")}
    end
  end

  defp cancel_queue(principal, task) do
    if task.state == "TASK_STATE_CANCELED" do
      :ok
    else
      cancel_pending(principal, task)
    end
  end

  defp cancel_pending(principal, task) do
    if terminal?(task) do
      {:error, {:conflict, "task_not_cancelable", "This task has ended."}}
    else
      # A running turn cannot be interrupted safely through Fountain's
      # track-wide interrupt. Only its still-queued prompt is cancelable.
      case PromptQueue.cancel(principal.user, task.track_id, task.id) do
        :ok ->
          :ok

        {:error, _} ->
          {:error, {:conflict, "task_not_cancelable", "Only queued tasks can be canceled."}}
      end
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
         # ownership: the task belongs to this OAuth principal; Access.thread_access checks its track below.
         %{} = queue <- PromptQueue.Store.get(task.id),
         {:ok, access} <- Access.thread_access(principal.user, task.track_id, queue.thread_id) do
      {:ok, task, access}
    else
      _ -> {:error, :not_found}
    end
  end

  defp refresh(%Task{state: state} = task, _) when state in @terminal, do: {:ok, task}

  defp refresh(task, access) do
    # ownership: accessible/2 established Access.track_access for this task;
    # its queue row supplies delivery status, never completion status.
    queue = PromptQueue.Store.get(task.id)

    case queue.status do
      :cancelled -> {:ok, Store.update(task, state: "TASK_STATE_CANCELED")}
      :failed -> {:ok, Store.update(task, state: "TASK_STATE_FAILED")}
      state when state in [:sent, :unconfirmed, :sending] -> reconcile(task, access)
      _ -> {:ok, task}
    end
  end

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
         text <- reply(page.events, turn.id, access.project.runtime) do
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

    if current.cursor != task.cursor or terminal?(current) do
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
      status: %{state: task.state, timestamp: DateTime.to_iso8601(task.updated_at)},
      artifacts: [
        %{artifactId: task.id <> "-reply", name: "Agent reply", parts: [%{text: task.result}]}
      ]
    }
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

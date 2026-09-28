defmodule Ravix.Tooling.Store do
  @moduledoc "Persistence for OAuth grants, mutation receipts and delegated tasks. Callers establish access."
  import Ecto.Query
  alias Ravix.Repo

  alias Ravix.Tooling.{
    Client,
    Credential,
    Grant,
    Receipt,
    ReplyChunk,
    Task,
    Tasks,
    ThreadCheckpoint
  }

  def client(id) when is_binary(id), do: Repo.get(Client, id)
  def client(_), do: nil
  def insert(row), do: Repo.insert!(row)

  def update(row, attrs) do
    changeset = Ecto.Changeset.change(row, attrs)
    changeset = force_payload(changeset, attrs)

    if match?(%Task{}, row), do: payload(:written, changeset.changes)
    Repo.update!(changeset)
  end

  # Large columns are absent from hot selects. Defaults aren't stored values,
  # so explicit resets must be forced even when they equal a schema default.
  defp force_payload(%{data: %Task{}} = changeset, attrs) do
    Enum.reduce(attrs, changeset, fn {key, value}, cs ->
      if key in [:result, :reply_events, :reply_prefix],
        do: Ecto.Changeset.force_change(cs, key, value),
        else: cs
    end)
  end

  defp force_payload(changeset, _attrs), do: changeset

  def transaction(fun), do: Repo.transaction(fun)
  def rollback(reason), do: Repo.rollback(reason)
  def grant(id), do: Repo.get(Grant, id)
  def lock_grant(id), do: Repo.one(from g in Grant, where: g.id == ^id, lock: "FOR UPDATE")
  def credential(hash), do: Repo.get(Credential, hash)

  def grants(user),
    do: Repo.all(from g in Grant, where: g.user_id == ^user, order_by: [desc: g.inserted_at])

  # Token checks can repeat throughout a stream. Sample activity once a minute
  # and condition the write so an older concurrent request cannot move it back.
  def record_use(id) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -60, :second)

    Repo.update_all(
      from(g in Grant,
        where: g.id == ^id and (is_nil(g.last_used_at) or g.last_used_at < ^cutoff)
      ),
      set: [last_used_at: now]
    )

    :ok
  end

  def revoke(id) do
    Repo.update_all(from(g in Grant, where: g.id == ^id), set: [revoked_at: DateTime.utc_now()])
    :ok
  end

  def claim_receipt(row) do
    now = DateTime.utc_now()

    attrs =
      row
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.merge(%{inserted_at: now, updated_at: now})

    {count, _} = Repo.insert_all(Receipt, [attrs], on_conflict: :nothing)
    {if(count == 1, do: :new, else: :existing), Repo.get!(Receipt, row.id)}
  end

  def receipt(id), do: Repo.get(Receipt, id)

  @small ~w(id track_id user_id client_id fingerprint state reconciled_at failure_code failure_message
            turn_id cursor cursor_conversation_id turn_seen reply_compacted reply_size reply_bytes failure_evidence
            inserted_at updated_at)a
  def task(id) do
    case Repo.one(from t in Task, where: t.id == ^id, select: struct(t, ^(@small ++ [:result]))) do
      %Task{reply_compacted: true, state: state} = task
      when state not in [
             "TASK_STATE_COMPLETED",
             "TASK_STATE_FAILED",
             "TASK_STATE_CANCELED",
             "TASK_STATE_REJECTED"
           ] ->
        %{task | result: reply(task.id)}

      task ->
        task
    end
  end

  def small_task(id),
    do: read_small(from(t in Task, where: t.id == ^id, select: struct(t, ^@small)))

  def lock_task(id),
    do:
      read_small(
        from(t in Task, where: t.id == ^id, select: struct(t, ^@small), lock: "FOR UPDATE")
      )

  defp read_small(query) do
    task = Repo.one(query)
    if task, do: payload(:read, Map.take(task, @small))
    task
  end

  def legacy_reply(id) do
    row =
      Repo.one(
        from t in Task,
          where: t.id == ^id,
          select: map(t, [:result, :reply_events, :reply_prefix])
      )

    payload(:read, row)
    row
  end

  def append_reply(id, cursor, body) do
    if body != "" do
      payload(:written, %{task_id: id, cursor: cursor, body: body})
      Repo.insert!(%ReplyChunk{task_id: id, cursor: cursor, body: body})
    end
  end

  def clear_reply(id), do: Repo.delete_all(from c in ReplyChunk, where: c.task_id == ^id)

  def reply(id) do
    chunks =
      Repo.all(from c in ReplyChunk, where: c.task_id == ^id, order_by: c.cursor, select: c.body)

    Enum.each(chunks, &payload(:read, &1))
    Enum.join(chunks)
  end

  # Bounded batches also clean terminal/held receipts, which aren't due threads.
  # ownership: no door for internal maintenance of receipts created through Tasks.send; no data is returned to a user.
  def legacy_tasks do
    Repo.all(
      from t in Task,
        join: q in Ravix.PromptQueue.Item,
        on: q.id == t.id,
        join: thread in Ravix.Tracks.Thread,
        on: thread.id == q.thread_id,
        join: track in Ravix.Tracks.Track,
        on: track.id == thread.track_id,
        join: project in Ravix.Projects.Project,
        on: project.id == track.project_id,
        where: not t.reply_compacted,
        order_by: t.id,
        limit: 5,
        select: {t.id, coalesce(thread.runtime, project.runtime)}
    )
  end

  def measure(rows, fun) do
    previous = Process.put({__MODULE__, :payload}, %{read: 0, written: 0})

    try do
      Enum.each(rows, fn {task, _} -> payload(:read, Map.take(task, @small)) end)
      fun.()
    after
      counts = Process.get({__MODULE__, :payload})

      Ravix.Trace.annotate(%{
        "ravix.task_payload_bytes_read" => counts.read,
        "ravix.task_payload_bytes_written" => counts.written
      })

      if previous,
        do: Process.put({__MODULE__, :payload}, previous),
        else: Process.delete({__MODULE__, :payload})
    end
  end

  defp payload(direction, value) do
    if counts = Process.get({__MODULE__, :payload}) do
      bytes = value |> Jason.encode_to_iodata!() |> IO.iodata_length()
      Process.put({__MODULE__, :payload}, Map.update!(counts, direction, &(&1 + bytes)))
    end
  end

  # ownership: Access.track_access, via Access.thread_access in Tasks.send
  # (send_prompt), authorized creation of these receipts. These joins correlate them to their
  # queue/thread/project; no new work is submitted
  # and no result is returned to a client. Public reads remain scoped in Tasks.
  defp pending do
    from t in Task,
      join: q in Ravix.PromptQueue.Item,
      on: q.id == t.id,
      join: thread in Ravix.Tracks.Thread,
      on: thread.id == q.thread_id,
      join: track in Ravix.Tracks.Track,
      on: track.id == thread.track_id,
      join: project in Ravix.Projects.Project,
      on: project.id == track.project_id,
      where:
        t.state not in [
          "TASK_STATE_COMPLETED",
          "TASK_STATE_FAILED",
          "TASK_STATE_CANCELED",
          "TASK_STATE_REJECTED"
        ] or
          (t.state == "TASK_STATE_FAILED" and is_nil(t.turn_id) and
             q.status != :failed)
  end

  def pending_threads do
    Repo.all(from [t, q, thread, track, p] in sweepable(), distinct: true, select: thread.id)
  end

  def record_reconciliation(id) do
    now = DateTime.utc_now()
    payload(:written, %{reconciled_at: now})
    Repo.update_all(from(t in Task, where: t.id == ^id), set: [reconciled_at: now])
    now
  end

  def due_threads(cursor, now, limit) do
    initial = DateTime.add(now, -3, :second)

    Repo.all(
      from [t, q, thread, track, p] in sweepable(),
        left_join: checkpoint in ThreadCheckpoint,
        on: checkpoint.id == thread.id and checkpoint.conversation_id == thread.conversation_id,
        where: thread.id > ^cursor,
        where:
          checkpoint.next_due_at <= ^now or
            (is_nil(checkpoint.next_due_at) and
               coalesce(t.reconciled_at, t.updated_at) <= ^initial),
        distinct: true,
        order_by: thread.id,
        limit: ^limit,
        select: thread.id
    )
  end

  # Held rows still receive queue hints, but cannot progress by polling Fountain.
  defp sweepable do
    from [t, q] in pending(),
      where:
        q.status in [:sent, :sending] or
          (q.status == :queued and t.state != "TASK_STATE_SUBMITTED") or
          (q.status == :failed and t.state != "TASK_STATE_FAILED") or
          (q.status == :unconfirmed and t.state != "TASK_STATE_INPUT_REQUIRED") or
          (q.status == :cancelled and t.state != "TASK_STATE_CANCELED")
  end

  def checkpoint(id, nil), do: %ThreadCheckpoint{id: id}

  def checkpoint(id, conversation_id) do
    Repo.get_by(ThreadCheckpoint, id: id, conversation_id: conversation_id) ||
      %ThreadCheckpoint{id: id, conversation_id: conversation_id}
  end

  def reset_checkpoint(_id, nil), do: :ok

  def reset_checkpoint(id, conversation_id) do
    Repo.insert_all(ThreadCheckpoint, [%{id: id, conversation_id: conversation_id}],
      on_conflict: :nothing
    )

    Repo.update_all(
      from(c in ThreadCheckpoint, where: c.id == ^id and c.conversation_id == ^conversation_id),
      set: [next_due_at: DateTime.utc_now(), unchanged: 0, signature: nil],
      inc: [generation: 1]
    )

    :ok
  end

  def finish_checkpoint(%{conversation_id: nil}, _signature), do: :ok

  def finish_checkpoint(before, signature) do
    Repo.insert_all(ThreadCheckpoint, [%{id: before.id, conversation_id: before.conversation_id}],
      on_conflict: :nothing
    )

    unchanged = if signature == before.signature, do: min(before.unchanged + 1, 3), else: 0
    delay = Enum.at([5, 60, 180, 300], unchanged)
    # A concurrent hint invalidates this attempt's cadence; never postpone that hint.
    Repo.update_all(
      from(c in ThreadCheckpoint,
        where:
          c.id == ^before.id and c.conversation_id == ^before.conversation_id and
            c.generation == ^before.generation
      ),
      set: [
        signature: signature,
        unchanged: unchanged,
        next_due_at: DateTime.add(DateTime.utc_now(), delay, :second)
      ],
      inc: [generation: 1]
    )

    :ok
  end

  def advance_checkpoint(_id, nil, _cursor), do: :ok
  def advance_checkpoint(_id, _conversation_id, nil), do: :ok

  # Called inside the receipt transaction: a crash cannot commit a reply without
  # the high-water mark inherited by the next task. Older receipts keep their own cursor.
  def advance_checkpoint(id, conversation_id, cursor) do
    Repo.insert_all(ThreadCheckpoint, [%{id: id, conversation_id: conversation_id}],
      on_conflict: :nothing
    )

    Repo.update_all(
      from(c in ThreadCheckpoint,
        where:
          c.id == ^id and c.conversation_id == ^conversation_id and
            (is_nil(c.cursor) or c.cursor < ^cursor)
      ),
      set: [cursor: cursor]
    )

    :ok
  end

  def reconciliation_rows(opts) do
    query = pending()

    query =
      if opts[:track_id],
        do: from([t] in query, where: t.track_id == ^opts[:track_id]),
        else: query

    query =
      if opts[:thread_id],
        do: from([t, q, thread] in query, where: thread.id == ^opts[:thread_id]),
        else: query

    Repo.all(
      from [t, q, thread, track, project] in query,
        select:
          {struct(t, ^@small),
           %{
             thread: map(thread, [:id, :conversation_id, :runtime]),
             project: map(project, [:runtime])
           }}
    )
  end

  # ownership: no door before this one -- the query establishes the same
  # owner/project/track membership door as Access.track_access, before paging.
  # Tasks.list additionally checks Access on every returned row.
  def tasks(user_id, client_id, opts) do
    query = visible_tasks(user_id, client_id)
    paginate_tasks(query, opts)
  end

  defp visible_tasks(user_id, client_id) do
    from task in Task,
      join: track in Ravix.Tracks.Track,
      on: track.id == task.track_id,
      join: project in Ravix.Projects.Project,
      on: project.id == track.project_id,
      left_join: tm in Ravix.Tracks.TrackMember,
      on: tm.track_id == track.id and tm.user_id == ^user_id,
      left_join: pm in Ravix.Projects.ProjectMember,
      on: pm.project_id == project.id and pm.user_id == ^user_id,
      where:
        task.user_id == ^user_id and task.client_id == ^client_id and
          is_nil(project.archived_at),
      where:
        (track.visibility == :project and project.user_id == ^user_id) or
          (is_nil(track.closed_at) and
             (track.created_by == ^user_id or not is_nil(tm.user_id) or
                (track.visibility == :project and not is_nil(pm.user_id))))
  end

  defp paginate_tasks(query, opts) do
    query = filter_tasks(query, opts)
    total = Repo.aggregate(query, :count)

    page =
      case opts.cursor do
        nil ->
          query

        {at, id} ->
          from t in query, where: t.updated_at < ^at or (t.updated_at == ^at and t.id < ^id)
      end

    rows =
      Repo.all(
        from t in page,
          select: struct(t, ^(@small ++ [:result])),
          order_by: [desc: t.updated_at, desc: t.id],
          limit: ^(opts.limit + 1)
      )

    {Enum.map(rows, fn row ->
       if row.reply_compacted and not Tasks.terminal?(row),
         do: %{row | result: reply(row.id)},
         else: row
     end), total}
  end

  defp filter_tasks(query, opts) do
    query = if opts.context, do: from(t in query, where: t.track_id == ^opts.context), else: query
    query = if opts.status, do: from(t in query, where: t.state == ^opts.status), else: query
    if opts.since, do: from(t in query, where: t.updated_at >= ^opts.since), else: query
  end
end

defmodule Ravix.Tooling.CompactReplyTest do
  use Ravix.DataCase, async: true
  use Mimic
  import Ravix.ToolingFixture
  alias Ravix.Fountain
  alias Ravix.Tooling.{ReplyChunk, Store, Task, Tasks}

  setup do
    user = insert_user()
    project = insert_project(user: user, runtime: "plain")
    track = insert_track(project: project, conversation_id: "compact")
    {principal, _, _} = principal(user)
    stub(Fountain, :client, fn -> Fountain.Client.new("https://fountain.test", "key") end)
    {:ok, task} = Tasks.send(principal, track.id, "hello", "compact")
    Ravix.PromptQueue.Store.mark_delivered(task.id)
    %{task: task, track: track, principal: principal}
  end

  test "five thousand events have bounded task rows and append only new reply fragments", c do
    stub(Fountain, :turns, fn _, _ -> {:ok, [turn(c.task.id, "running")]} end)
    owner = self()
    handler = "compact-#{c.task.id}"

    :telemetry.attach(
      handler,
      [:ravix, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == owner, do: send(owner, {:sql, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for pass <- 1..50 do
      expect(Fountain, :events_page, fn _, _, opts ->
        assert opts[:after] == if(pass == 1, do: nil, else: (pass - 1) * 100)
        events = for id <- ((pass - 1) * 100 + 1)..(pass * 100), do: event(id, "line\n")
        {:ok, %{events: events, next_cursor: pass * 100, has_more: true}}
      end)

      drain_sql()
      assert :ok = Tasks.reconcile_rows(Store.reconciliation_rows([]))
      queries = drain_sql()

      task_reads =
        Enum.filter(queries, &(String.starts_with?(&1, "SELECT") and &1 =~ "tooling_tasks"))

      assert task_reads != []

      for query <- task_reads do
        refute query =~ ~s(."reply_events")
        refute query =~ ~s(."result")
        refute query =~ ~s(."reply_prefix")
      end

      for query <- Enum.filter(queries, &String.starts_with?(&1, "UPDATE")) do
        refute query =~ ~s("reply_events" =)
        refute query =~ ~s("result" =)
      end

      stored = Repo.get!(Task, c.task.id)
      assert stored.result == ""
      assert stored.reply_events == []

      [[bytes]] =
        Repo.query!(
          "SELECT octet_length(row_to_json(t)::text) FROM ravix.tooling_tasks t WHERE id=$1",
          [c.task.id]
        ).rows

      assert bytes < 2048
      assert byte_size(Jason.encode!(stored.failure_evidence)) < 1024
      assert Repo.aggregate(ReplyChunk, :count) == pass
      assert Store.reply(c.task.id) == String.duplicate("line\n", pass * 100)
    end

    # No process memory survives between these calls; a freshly loaded receipt
    # resumes the persisted cursor and does not replay any accumulated output.
    expect(Fountain, :turns, fn _, _ -> {:ok, [turn(c.task.id, "completed")]} end)

    expect(Fountain, :events_page, fn _, _, opts ->
      assert opts[:after] == 5000
      {:ok, %{events: [], next_cursor: 5000, has_more: false}}
    end)

    assert {:ok, task} = Tasks.get(c.principal, c.task.id)
    assert task.state == "TASK_STATE_COMPLETED"
    assert task.result == String.duplicate("line\n", 5000)
  end

  test "reply storage stops at the artifact cap but later failure evidence is retained", c do
    stub(Fountain, :turns, fn _, _ -> {:ok, [turn(c.task.id, "running")]} end)

    for n <- 1..5 do
      expect(Fountain, :events_page, fn _, _, _ ->
        {:ok,
         %{events: [event(n, String.duplicate("x", 30_000))], next_cursor: n, has_more: false}}
      end)

      assert :ok = Tasks.reconcile_rows(Store.reconciliation_rows([]))
    end

    assert String.length(Store.reply(c.task.id)) == 64_000
    assert Repo.aggregate(ReplyChunk, :count) == 3

    events =
      Enum.map(Ravix.AgentOutageFixture.events(), &Map.update!(&1, "id", fn id -> id + 10 end))

    expect(Fountain, :turns, fn _, _ -> {:ok, [turn(c.task.id, "completed")]} end)

    expect(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: events, next_cursor: 18, has_more: false}}
    end)

    assert {:ok, %{state: "TASK_STATE_FAILED", failure_code: "agent_provider_unreachable"}} =
             Tasks.get(c.principal, c.task.id)
  end

  test "legacy journals are converted once, including held and terminal receipts", c do
    legacy = Ravix.AgentOutageFixture.events()
    Ravix.PromptQueue.Store.set_status(c.task.id, :unconfirmed)

    Store.update(c.task,
      state: "TASK_STATE_INPUT_REQUIRED",
      reply_events: legacy,
      result: "old",
      cursor: 8,
      turn_id: "mine"
    )

    assert not Store.small_task(c.task.id).reply_compacted
    Tasks.compact_legacy()
    converted = Repo.get!(Task, c.task.id)
    assert converted.reply_events == []
    assert converted.reply_prefix == ""
    assert converted.reply_compacted
    assert converted.failure_evidence["transport"]
    assert Store.legacy_tasks() == []

    # A writer from the old release can repopulate the legacy column. The
    # migration's trigger marks that row for another fenced conversion.
    Store.update(converted,
      reply_events: legacy,
      result: "old writer",
      state: "TASK_STATE_COMPLETED"
    )

    assert not Store.small_task(c.task.id).reply_compacted
    Tasks.compact_legacy()

    assert %{reply_events: [], reply_compacted: true, result: "old writer"} =
             Repo.get!(Task, c.task.id)

    assert Store.legacy_tasks() == []
  end

  test "combining characters cannot bypass the byte cap or leave invalid UTF-8", c do
    stub(Fountain, :turns, fn _, _ -> {:ok, [turn(c.task.id, "running")]} end)

    expect(Fountain, :events_page, fn _, _, _ ->
      text = "a" <> String.duplicate("\u0301", 150_000)
      {:ok, %{events: [event(1, text)], next_cursor: 1, has_more: false}}
    end)

    assert :ok = Tasks.reconcile_rows(Store.reconciliation_rows([]))
    text = Store.reply(c.task.id)
    assert String.valid?(text)
    assert byte_size(text) == 255_999
    assert Store.small_task(c.task.id).reply_bytes == 255_999

    expect(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [event(2, "more")], next_cursor: 2, has_more: false}}
    end)

    assert :ok = Tasks.reconcile_rows(Store.reconciliation_rows([]))
    assert Store.reply(c.task.id) == text <> "m"
    assert Store.small_task(c.task.id).reply_bytes == 256_000
  end

  test "an explicit empty result overwrites a large value omitted by a narrow lock", c do
    Store.update(c.task, result: "old artifact")

    Store.transaction(fn ->
      current = Store.lock_task(c.task.id)
      assert current.result == ""
      Store.update(current, result: "")
    end)

    assert Repo.get!(Task, c.task.id).result == ""
  end

  test "fragment and cursor writes roll back together", c do
    assert {:error, :crash} =
             Store.transaction(fn ->
               Store.append_reply(c.task.id, 1, "uncommitted")
               Store.update(Store.lock_task(c.task.id), cursor: 1)
               Store.rollback(:crash)
             end)

    assert Store.reply(c.task.id) == ""
    assert Store.small_task(c.task.id).cursor == nil
  end

  defp event(id, data),
    do: %{
      "id" => id,
      "turn_id" => "mine",
      "kind" => "output",
      "stream" => "stdout",
      "data" => data
    }

  defp turn(task_id, status),
    do: %{id: "mine", client_request_id: task_id, status: status}

  defp drain_sql(acc \\ []) do
    receive do
      {:sql, query} -> drain_sql([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

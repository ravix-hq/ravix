defmodule Ravix.Tooling.JournalBench do
  use Ravix.DataCase, async: false
  use Mimic
  import Ravix.ToolingFixture
  alias Ravix.Fountain
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Tooling.{Tasks, Store}

  test "five thousand events on one unfinished turn" do
    user = insert_user()
    project = insert_project(user: user, runtime: "plain")
    {principal, _, _} = principal(user)
    track = insert_track(project: project, conversation_id: "journal-bench")
    client = FakeTransport.client([], verify: false)
    stub(Fountain, :client, fn -> client end)
    {:ok, task} = Tasks.send(principal, track.id, "hello", "journal-bench")
    Ravix.PromptQueue.Store.mark_delivered(task.id)
    owner = self()
    handler = "journal-bench"
    :telemetry.attach(handler, [:ravix, :repo, :query], fn _, measurements, metadata, _ ->
      send(owner, {:db, measurements, metadata.query})
    end, nil)
    on_exit(fn -> :telemetry.detach(handler) end)

    for pass <- 1..50 do
      base = "/api/conversations/#{track.conversation_id}"
      FakeTransport.expect(client, %{method: "GET", path: base <> "/turns"},
        {200, [], %{data: [%{id: task.id, client_request_id: task.id, status: "running"}]}})
      FakeTransport.expect(client, %{method: "GET", path: base <> "/events"}, fn call ->
        after_id = String.to_integer(call.query["after"] || "0")
        events = for id <- (after_id + 1)..(after_id + 100) do
          %{id: id, turn_id: task.id, kind: "output", stream: "stdout", data: String.duplicate("x", 256)}
        end
        {200, [], %{data: events, meta: %{next_cursor: after_id + 100, has_more: true}}}
      end)
      drain([])
      {before_red, _} = :erlang.statistics(:reductions)
      {us, :ok} = :timer.tc(fn -> Tasks.reconcile_rows(Store.reconciliation_rows([])) end)
      {after_red, _} = :erlang.statistics(:reductions)
      queries = drain([])
      db = Enum.sum(Enum.map(queries, fn {m, _} -> m.query_time + Map.get(m, :decode_time, 0) end))
      [[bytes]] = Repo.query!("SELECT octet_length(row_to_json(t)::text) FROM ravix.tooling_tasks t WHERE id=$1", [task.id]).rows
      IO.puts("JOURNAL pass=#{pass} events=#{pass * 100} reductions=#{after_red-before_red} elapsed_us=#{us} db_us=#{System.convert_time_unit(db, :native, :microsecond)} row_bytes=#{bytes}")
    end
  end

  defp drain(acc) do
    receive do
      {:db, m, q} -> drain([{m, q} | acc])
    after
      0 -> acc
    end
  end
end

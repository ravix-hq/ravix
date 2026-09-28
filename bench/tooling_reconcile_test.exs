defmodule Ravix.Tooling.ReconcileBench do
  use Ravix.DataCase, async: false
  use Mimic
  import Ravix.ToolingFixture
  alias Ravix.Fountain
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Tooling.{Tasks, Store}

  test "long histories across ten threads and five passes" do
    user = insert_user()
    project = insert_project(user: user, runtime: "plain")
    {p, _, _} = principal(user)
    client = FakeTransport.client([], verify: false)
    stub(Fountain, :client, fn -> client end)

    rows =
      for n <- 1..10 do
        track = insert_track(project: project, conversation_id: "bench-#{n}")
        {:ok, task} = Tasks.send(p, track.id, "hello", "bench-#{n}")
        Ravix.PromptQueue.Store.mark_delivered(task.id)
        {task, track}
      end

    for pass <- 1..5 do
      for {task, track} <- rows do
        base = "/api/conversations/#{track.conversation_id}"

        FakeTransport.expect(
          client,
          %{method: "GET", path: base <> "/turns"},
          {200, [],
           %{
             data: [
               %{
                 id: task.id,
                 client_request_id: task.id,
                 status: if(pass == 5, do: "completed", else: "running")
               }
             ]
           }}
        )

        # Supply more pages than needed; count actual transport calls below.
        for _ <- 1..15 do
          FakeTransport.expect(client, %{method: "GET", path: base <> "/events"}, fn call ->
            after_id = String.to_integer(call.query["after"] || "0")

            events =
              for id <- (after_id + 1)..min(after_id + 100, 1200), after_id < 1200 do
                %{
                  id: id,
                  turn_id: if(id <= 1000, do: "old", else: task.id),
                  kind: "output",
                  stream: "stdout",
                  data: String.duplicate("x", 256)
                }
              end

            {200, [],
             %{
               data: events,
               meta: %{next_cursor: min(after_id + 100, 1200), has_more: after_id + 100 < 1200}
             }}
          end)
        end
      end

      {before_red, _} = :erlang.statistics(:reductions)
      before_calls = length(FakeTransport.calls(client))
      {us, :ok} = :timer.tc(fn -> Tasks.reconcile_rows(Store.reconciliation_rows([])) end)
      {after_red, _} = :erlang.statistics(:reductions)

      IO.puts(
        "BENCH pass=#{pass} calls=#{length(FakeTransport.calls(client)) - before_calls} reductions=#{after_red - before_red} elapsed_ms=#{div(us, 1000)}"
      )
    end
  end

  test "ten minutes of unchanged backstop sweeps over ten long threads" do
    import Ecto.Query
    alias Ravix.Tooling.Task
    user = insert_user()
    project = insert_project(user: user, runtime: "plain")
    {p, _, _} = principal(user)
    client = FakeTransport.client([], verify: false)
    stub(Fountain, :client, fn -> client end)
    origin = DateTime.utc_now()

    rows =
      for n <- 1..10 do
        track = insert_track(project: project, conversation_id: "idle-#{n}")
        {:ok, task} = Tasks.send(p, track.id, "hello", "idle-#{n}")
        Ravix.PromptQueue.Store.mark_delivered(task.id)

        task
        |> Ecto.Changeset.change(
          state: "TASK_STATE_WORKING",
          turn_id: task.id,
          cursor: 1200,
          reconciled_at: DateTime.add(origin, -60, :second)
        )
        |> Repo.update!()

        base = "/api/conversations/#{track.conversation_id}"

        for _ <- 1..20 do
          FakeTransport.expect(
            client,
            %{method: "GET", path: base <> "/turns"},
            {200, [], %{data: [%{id: task.id, client_request_id: task.id, status: "running"}]}}
          )

          FakeTransport.expect(client, %{method: "GET", path: base <> "/events"}, fn call ->
            assert call.query["after"] == "1200"
            {200, [], %{data: [], meta: %{next_cursor: 1200, has_more: false}}}
          end)
        end

        {task, track}
      end

    {us, reductions} =
      Enum.reduce(0..600//5, {0, 0}, fn seconds, {us, reds} ->
        now = DateTime.add(origin, seconds, :second)
        {before_red, _} = :erlang.statistics(:reductions)

        {elapsed, ids} =
          :timer.tc(fn ->
            ids = Store.due_threads("", now, 50)

            Enum.each(ids, fn id ->
              :ok = Tasks.reconcile_rows(Store.reconciliation_rows(thread_id: id))
            end)

            ids
          end)

        {after_red, _} = :erlang.statistics(:reductions)
        # Advance durable timestamps onto the synthetic clock, outside the timed work.
        for {task, track} <- rows, track.id in ids do
          Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [reconciled_at: now])

          if function_exported?(Store, :checkpoint, 2) do
            cp = apply(Store, :checkpoint, [track.id, track.conversation_id])
            delta = DateTime.diff(cp.next_due_at, DateTime.utc_now(), :millisecond)
            Store.update(cp, next_due_at: DateTime.add(now, round(delta / 1000), :second))
          end
        end

        {us + elapsed, reds + after_red - before_red}
      end)

    IO.puts(
      "BENCH idle threads=10 sweeps=121 simulated_seconds=600 calls=#{length(FakeTransport.calls(client))} reductions=#{reductions} elapsed_ms=#{div(us, 1000)}"
    )
  end

  test "JSON decoding versus reply parsing" do
    events =
      for id <- 1..200 do
        %{
          "id" => id,
          "turn_id" => "reply",
          "kind" => "output",
          "stream" => "stdout",
          "data" => String.duplicate("x", 256)
        }
      end

    json = Jason.encode!(%{data: events})

    for {name, fun} <- [
          {"decode_200_events", fn -> Jason.decode!(json) end},
          {"old_reply_page", fn -> Ravix.Tracks.Transcript.page(events, "plain") end},
          {"new_reply_blocks", fn -> Ravix.Tracks.Transcript.blocks_for_turn(events, "plain") end}
        ] do
      {before_red, _} = :erlang.statistics(:reductions)
      {us, _} = :timer.tc(fn -> for _ <- 1..100, do: fun.() end)
      {after_red, _} = :erlang.statistics(:reductions)

      IO.puts(
        "BENCH component=#{name} repetitions=100 reductions=#{after_red - before_red} elapsed_ms=#{div(us, 1000)}"
      )
    end
  end
end

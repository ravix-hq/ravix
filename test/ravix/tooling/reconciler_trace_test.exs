defmodule Ravix.Tooling.ReconcilerTraceTest do
  use Ravix.DataCase, async: false
  use Ravix.TraceCase, async: false
  use Mimic
  import Ravix.ToolingFixture
  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.Fountain
  alias Ravix.Fountain.FakeTransport
  alias Ravix.PromptQueue.Store, as: Queue
  alias Ravix.Tooling.{Reconciler, Tasks}

  test "provider requests are children of the thread and sweep spans" do
    stub(Fountain, :client, fn -> Fountain.Client.new("https://fountain.test", "key") end)
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "traced-reconcile")
    {p, _, _} = principal(user)
    {:ok, task} = Tasks.send(p, track.id, "hello", "trace")
    Queue.mark_delivered(task.id)

    task
    |> Ecto.Changeset.change(updated_at: DateTime.add(DateTime.utc_now(), -10, :second))
    |> Repo.update!()

    base = "/api/conversations/#{track.conversation_id}"

    client =
      FakeTransport.client([
        {%{method: "GET", path: base <> "/turns"},
         {200, [], %{data: [%{id: "t", client_request_id: task.id, status: "running"}]}}},
        {%{method: "GET", path: base <> "/events"},
         {200, [], %{data: [], meta: %{has_more: false}}}}
      ])

    stub(Fountain, :client, fn -> client end)
    server = start_supervised!({Reconciler, interval: false, subscribe: false})
    Sandbox.allow(Repo, self(), server)
    allow(Fountain, self(), server)
    Reconciler.tick(server)
    provider = await_span("fountain.request")
    thread = await_span("tooling.reconcile.thread")
    sweep = await_span("tooling.reconcile.sweep")
    assert span(provider, :parent_span_id) == span(thread, :span_id)
    assert span(thread, :parent_span_id) == span(sweep, :span_id)
    assert attributes(thread)["ravix.events_read"] == 0
    assert attributes(thread)["ravix.pages_read"] == 1
    assert attributes(sweep)["ravix.thread_count"] == 1
    assert span(thread, :end_time) >= span(thread, :start_time)
  end
end

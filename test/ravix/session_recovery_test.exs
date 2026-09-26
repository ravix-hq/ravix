defmodule Ravix.SessionRecoveryTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.Fountain
  alias Ravix.Fountain.FakeTransport
  alias Ravix.PromptQueue.{Server, Store}

  setup do
    user = insert_user()
    project = insert_project(user: user, repo_full_name: nil, installation_id: nil, vault_id: nil)
    track = insert_track(project: project, conversation_id: "reset-thread")
    stub(Ravix.Projects, :prepare_machine, fn _, _ -> :ok end)
    stub(Ravix.Previews, :prepare_agent_preview, fn _ -> "" end)
    server = server()
    %{user: user, project: project, track: track, server: server}
  end

  test "replayed initialize failure, crash, and session_gone restore ordered assignments once",
       ctx do
    {:ok, plan} =
      Ravix.Plans.create(ctx.user, ctx.project.id, %{
        "title" => "Track reliability",
        "items" => [
          %{"id" => "gate", "title" => "Gate queued prompts", "brief" => "Wait for setup"},
          %{"id" => "context", "title" => "Restore context", "acceptance" => "Once per reset"},
          %{"id" => "sibling", "title" => "Private sibling work"}
        ]
      })

    {:ok, %{items: items}} = Ravix.Plans.get(ctx.user, plan.id)

    for item <- Enum.take(items, 2) do
      Ravix.Plans.Item
      |> Repo.get!(item.id)
      |> Ecto.Changeset.change(track_id: ctx.track.id)
      |> Repo.update!()
    end

    first = enqueue(ctx, "Continue the gate")
    second = enqueue(ctx, "Then restore context")
    events = replay()
    client = provider([delivery(events), delivery(events)] |> List.flatten())
    Server.tick(ctx.server)
    assert Store.delivered_reset(ctx.track.id) == 4
    assert Store.get(first.id).status == :sent
    assert Store.get(second.id).status == :queued

    # A different worker has no process-local knowledge of the first delivery.
    Server.tick(server())
    [first_prompt, second_prompt] = prompts(client)
    assert first_prompt =~ ctx.track.workdir
    assert first_prompt =~ ctx.track.branch
    assert first_prompt =~ "Do not edit, stage, commit"
    assert first_prompt =~ "1. Gate queued prompts (gate)"
    assert first_prompt =~ "2. Restore context (context)"
    assert first_prompt =~ "Wait for setup"
    assert first_prompt =~ "Once per reset"
    refute first_prompt =~ "Private sibling work"
    assert String.ends_with?(first_prompt, "Continue the gate")
    refute second_prompt =~ "session context restored"
    assert second_prompt == "Then restore context"
    assert Store.get(second.id).status == :sent
  end

  test "normal turns and unrelated or malformed events carry no preamble", ctx do
    enqueue(ctx, "Normal prompt")

    events = [
      stage(1, "adapter_crashed"),
      %{"id" => 2, "kind" => "output", "data" => Jason.encode!(%{reason: "session_gone"})},
      %{"id" => 3, "kind" => "stage", "data" => "not json"},
      %{"id" => 4, "kind" => "stage", "data" => "{}"}
    ]

    client = provider(delivery(events))
    Server.tick(ctx.server)
    assert prompts(client) == ["Normal prompt"]
    assert Store.delivered_reset(ctx.track.id) == 0
  end

  test "a later reset needs another preamble, including a reset during the previous POST", ctx do
    enqueue(ctx, "First")
    enqueue(ctx, "Second")
    client = provider(delivery([stage(1)]) ++ delivery([stage(1), stage(2)]))
    Server.tick(ctx.server)
    Server.tick(ctx.server)
    assert Enum.all?(prompts(client), &String.contains?(&1, "session context restored"))
    assert Store.delivered_reset(ctx.track.id) == 2
  end

  test "ambiguous POST confirmation commits the prepared receipt on another worker", ctx do
    first = enqueue(ctx, "First")
    enqueue(ctx, "Second")

    client =
      provider(
        delivery([stage(7)], {:error, :timeout}) ++
          [
            {%{method: "GET", path: "/api/conversations/reset-thread/turns"},
             {200, [], %{data: [%{id: "t1", status: "completed", client_request_id: first.id}]}}}
          ] ++ delivery([stage(7)])
      )

    Server.tick(ctx.server)
    assert Store.get(first.id).status == :unconfirmed
    assert Store.delivered_reset(ctx.track.id) == 0
    another = server()
    Server.tick(another)
    assert Store.get(first.id).status == :sent
    assert Store.delivered_reset(ctx.track.id) == 7
    Server.tick(another)
    [first_prompt, second_prompt] = prompts(client)
    assert first_prompt =~ "session context restored"
    assert second_prompt == "Second"
  end

  test "history unavailable holds the prompt without a POST or receipt", ctx do
    row = enqueue(ctx, "Wait")

    client =
      provider([
        idle(),
        {%{method: "GET", path: "/api/conversations/reset-thread/events"},
         {503, [], %{error: "offline"}}}
      ])

    Server.tick(ctx.server)
    assert Store.get(row.id).status == :queued
    assert Store.get(row.id).error =~ "session history"
    assert prompts(client) == []
    assert Store.delivered_reset(ctx.track.id) == 0
  end

  test "a definite rejection does not consume the reset", ctx do
    row = enqueue(ctx, "Try")
    client = provider(delivery([stage(9)], {400, [], %{error: "refused"}}))
    Server.tick(ctx.server)
    assert Store.get(row.id).status == :failed
    assert Store.delivered_reset(ctx.track.id) == 0
    assert [prompt] = prompts(client)
    assert prompt =~ "No plan items assigned."
  end

  test "receipt on another thread never consumes this thread's reset", ctx do
    {:ok, other} =
      Ravix.Tracks.Store.create_thread(%{
        track_id: ctx.track.id,
        conversation_id: "other",
        title: "Other thread on the same track"
      })

    {:ok, other_row} =
      Store.enqueue(
        ctx.track.id,
        ctx.user.id,
        ctx.user.login,
        Ecto.UUID.generate(),
        %{prompt: "Other", images: []},
        other.id
      )

    assert Store.claim(other_row.id)
    Store.prepare_reset(other_row.id, 100)
    Store.mark_delivered(other_row.id)
    enqueue(ctx, "This thread")
    client = provider(delivery([stage(1)]))
    Server.tick(ctx.server)
    assert [prompt] = prompts(client)
    assert prompt =~ "session context restored"
    assert Store.delivered_reset(ctx.track.id) == 1
  end

  test "competing workers cannot send two preambles for one reset", ctx do
    enqueue(ctx, "First")
    enqueue(ctx, "Second")
    test = self()

    delayed = fn _call ->
      send(test, {:posting, self()})

      receive do
        :accept -> {202, [], %{data: %{ok: true}}}
      end
    end

    client = provider(delivery([stage(11)], delayed) ++ delivery([stage(11)]))
    another = server()
    pending = Task.async(fn -> Server.tick(ctx.server) end)
    assert_receive {:posting, sender}, 2_000
    Server.tick(another)
    assert length(prompts(client)) == 1
    send(sender, :accept)
    assert :ok = Task.await(pending)
    Server.tick(another)
    [first, second] = prompts(client)
    assert first =~ "session context restored"
    assert second == "Second"
  end

  test "access revoked during history fetch prevents delivery", ctx do
    row = enqueue(ctx, "Private")

    response = fn _ ->
      ctx.track
      |> Ecto.Changeset.change(closed_at: DateTime.utc_now())
      |> Repo.update!()

      {200, [], %{data: [stage(1)]}}
    end

    client =
      provider([
        idle(),
        {%{method: "GET", path: "/api/conversations/reset-thread/events"}, response}
      ])

    Server.tick(ctx.server)
    assert Store.get(row.id).status == :cancelled
    assert prompts(client) == []
    assert Store.delivered_reset(ctx.track.id) == 0
  end

  defp server do
    pid =
      start_supervised!(
        Supervisor.child_spec({Server, name: nil, interval: false}, id: make_ref())
      )

    Sandbox.allow(Repo, self(), pid)
    for mod <- [Fountain, Ravix.Projects, Ravix.Previews], do: allow(mod, self(), pid)
    pid
  end

  defp enqueue(ctx, prompt) do
    {:ok, row} =
      Store.enqueue(ctx.track.id, ctx.user.id, ctx.user.login, Ecto.UUID.generate(), %{
        prompt: prompt,
        images: []
      })

    row
  end

  defp provider(script) do
    client = FakeTransport.client(script, max_retries: 0)
    stub(Fountain, :client, fn -> client end)
    client
  end

  defp idle do
    {%{method: "GET", path: "/api/conversations/reset-thread"},
     {200, [], %{data: %{id: "reset-thread", status: "idle"}}}}
  end

  defp delivery(events, response \\ {202, [], %{data: %{ok: true}}}) do
    [
      idle(),
      {%{method: "GET", path: "/api/conversations/reset-thread/events"},
       {200, [], %{data: events}}},
      {%{method: "POST", path: "/api/conversations/reset-thread/prompts"}, response}
    ]
  end

  defp prompts(client) do
    client
    |> FakeTransport.calls()
    |> Enum.filter(&(&1.method == "POST"))
    |> Enum.map(& &1.body["prompt"])
  end

  defp stage(id, reason \\ "session_gone") do
    %{
      "id" => id,
      "turn_id" => "turn-#{id}",
      "kind" => "stage",
      "stage" => "session",
      "state" => "done",
      "data" => Jason.encode!(%{event: "restarted", reason: reason, turn_id: "turn-#{id}"})
    }
  end

  # Reconstructed from the d62d756c incident chronology, using Fountain's
  # recorded stage-event wire format; this is not a dump of private prompts.
  defp replay do
    [
      %{"id" => 1, "kind" => "stage", "stage" => "turn", "state" => "started", "data" => "{}"},
      %{
        "id" => 2,
        "kind" => "stage",
        "stage" => "runtime",
        "state" => "failed",
        "data" => Jason.encode!(%{message: "ACP initialize error"})
      },
      stage(3, "adapter_crashed"),
      stage(4),
      %{"id" => 5, "kind" => "stage", "stage" => "turn", "state" => "completed", "data" => "{}"}
    ]
  end
end

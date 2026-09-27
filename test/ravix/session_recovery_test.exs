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
    client = provider(delivery(events) ++ delivery([], accepted(), 5))
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
    assert first_prompt =~ "reported status: in progress"
    assert first_prompt =~ "Skip items confirmed done"
    assert first_prompt =~ "check git log and the track's PRs"
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
    client = provider(delivery([stage(1)]) ++ delivery([stage(2)], accepted(), 1))
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
          ] ++ delivery([], accepted(), 7)
      )

    Server.tick(ctx.server)
    assert Store.get(first.id).status == :unconfirmed
    assert Store.delivered_reset(ctx.track.id) == 0
    assert Store.recovery_scan(ctx.track.id) == {0, false}
    assert Store.get(first.id).session_scan_id == 7
    another = server()
    Server.tick(another)
    assert Store.get(first.id).status == :sent
    assert Store.delivered_reset(ctx.track.id) == 7
    assert Store.recovery_scan(ctx.track.id) == {7, false}
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

    token = Ecto.UUID.generate()
    assert Store.claim(other_row.id, token)
    assert Store.prepare_recovery(other_row.id, token, 100, 100)
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

    client = provider(delivery([stage(11)], delayed) ++ delivery([], accepted(), 11))
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

  test "legacy sent history baselines old resets once, then scans only newer events", ctx do
    legacy = enqueue(ctx, "Delivered before the feature")
    Store.mark_delivered(legacy.id)
    assert Store.recovery_scan(ctx.track.id) == {0, true}
    first = enqueue(ctx, "First after deploy")
    second = enqueue(ctx, "After a new reset")
    old_reset = Map.put(stage(20), "ts", "2026-01-01T00:00:00Z")
    client = provider(delivery([old_reset]) ++ delivery([stage(21)], accepted(), 20))

    Server.tick(ctx.server)
    assert prompts(client) == ["First after deploy"]
    assert Store.get(first.id).session_reset_id == nil
    assert Store.get(first.id).session_scan_id == 20
    assert Store.recovery_scan(ctx.track.id) == {20, false}

    Server.tick(server())
    [_, restored] = prompts(client)
    assert restored =~ ctx.track.workdir
    assert Store.get(second.id).session_reset_id == 21
    assert event_cursors(client) == ["0", "20"]
  end

  test "multiple pages commit their tail and the next delivery reads only after that cursor",
       ctx do
    enqueue(ctx, "First")
    enqueue(ctx, "Second")

    client =
      provider(
        [
          idle(),
          page([stage(2)], 0, %{has_more: true, next_cursor: 2}),
          page([%{"id" => 3, "kind" => "output", "data" => "reply"}], 2),
          post(accepted())
        ] ++ delivery([stage(2)], accepted(), 3)
      )

    Server.tick(ctx.server)
    assert event_cursors(client) == ["0", "2"]
    assert Store.recovery_scan(ctx.track.id) == {3, false}
    Server.tick(server())
    assert event_cursors(client) == ["0", "2", "3"]
    [first, second] = prompts(client)
    assert first =~ "session context restored"
    assert second == "Second"
  end

  test "a later page failure consumes neither the cursor nor reset", ctx do
    row = enqueue(ctx, "After history returns")
    first_page = page([stage(4)], 0, %{has_more: true, next_cursor: 4})

    client =
      provider([
        idle(),
        first_page,
        {event_request(4), {503, [], %{error: "offline"}}},
        idle(),
        first_page,
        page([], 4),
        post(accepted())
      ])

    Server.tick(ctx.server)
    assert Store.get(row.id).status == :queued
    assert Store.get(row.id).session_scan_id == nil
    assert Store.recovery_scan(ctx.track.id) == {0, false}
    assert prompts(client) == []
    Server.tick(server())
    assert Store.recovery_scan(ctx.track.id) == {4, false}
    assert [prompt] = prompts(client)
    assert prompt =~ ctx.track.workdir
    assert event_cursors(client) == ["0", "4", "0", "4"]
  end

  test "a stalled page cursor holds delivery without committing its events", ctx do
    row = enqueue(ctx, "Wait for valid pagination")
    client = provider([idle(), page([stage(1)], 0, %{has_more: true, next_cursor: 0})])
    Server.tick(ctx.server)
    assert Store.get(row.id).status == :queued
    assert Store.recovery_scan(ctx.track.id) == {0, false}
    assert prompts(client) == []
    assert event_cursors(client) == ["0"]
  end

  test "an empty legacy baseline commits zero so the next reset is not baselined away", ctx do
    legacy = enqueue(ctx, "Legacy")
    Store.mark_delivered(legacy.id)
    enqueue(ctx, "Baseline")
    enqueue(ctx, "After reset")
    client = provider(delivery([]) ++ delivery([stage(1)]))
    Server.tick(ctx.server)
    assert Store.recovery_scan(ctx.track.id) == {0, false}
    Server.tick(server())
    [first, second] = prompts(client)
    assert first == "Baseline"
    assert second =~ "session context restored"
    assert event_cursors(client) == ["0", "0"]
  end

  test "a rejected legacy baseline is not committed", ctx do
    legacy = enqueue(ctx, "Old")
    Store.mark_delivered(legacy.id)
    row = enqueue(ctx, "New")

    client =
      provider(delivery([stage(12)], {400, [], %{error: "refused"}}) ++ delivery([stage(12)]))

    Server.tick(ctx.server)
    assert Store.get(row.id).status == :failed
    assert Store.recovery_scan(ctx.track.id) == {0, true}
    assert :ok = Ravix.PromptQueue.retry(ctx.user, ctx.track.id, row.id)
    Server.tick(server())
    assert prompts(client) == ["New", "New"]
    assert event_cursors(client) == ["0", "0"]
    assert Store.recovery_scan(ctx.track.id) == {12, false}
  end

  for {report, label} <- [
        {{:ok, %{state: :merged}}, "done"},
        {{:ok, %{state: :open}}, "in review"},
        {{:error, :offline}, "unknown (status unavailable)"}
      ] do
    test "recovery includes derived item status: #{label}", ctx do
      ctx.project
      |> Ecto.Changeset.change(repo_full_name: "org/repo", installation_id: 1)
      |> Repo.update!()

      {:ok, _} =
        Ravix.Plans.create(ctx.user, ctx.project.id, %{
          "title" => "Assigned",
          "items" => [%{"id" => "assigned", "title" => "Existing work"}]
        })

      Ravix.Plans.Item
      |> Repo.get!("assigned")
      |> Ecto.Changeset.change(track_id: ctx.track.id)
      |> Repo.update!()

      stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)
      stub(Ravix.GitHub, :plan_pulls, fn _, _, _ -> {:ok, %{pulls: [], complete: true}} end)
      stub(Ravix.GitHub, :pull_for_track, fn _, _, _, _, _ -> unquote(Macro.escape(report)) end)
      enqueue(ctx, "Continue")
      client = provider(delivery([stage(1)]))
      Server.tick(ctx.server)
      assert [prompt] = prompts(client)
      assert prompt =~ "reported status: #{unquote(label)}"
      assert prompt =~ "Skip items confirmed done"
      assert prompt =~ "check git log and the track's PRs"
      assert prompt =~ "verify which items each PR covers"
    end
  end

  test "a superseded preparation cannot overwrite the next claim's recovery receipt", ctx do
    row = enqueue(ctx, "Continue")
    old_token = Ecto.UUID.generate()
    new_token = Ecto.UUID.generate()
    assert Store.claim(row.id, old_token)
    Store.release_claim(row.id, old_token)
    assert Store.claim(row.id, new_token)
    assert Store.prepare_recovery(row.id, new_token, 10, 12)
    refute Store.prepare_recovery(row.id, old_token, 20, 25)
    assert Store.get(row.id).session_reset_id == 10
    assert Store.get(row.id).session_scan_id == 12
    assert Store.begin_post(row.id, new_token)
    refute Store.prepare_recovery(row.id, new_token, 20, 25)
  end

  test "linked completed and active items on one track retain their individual statuses", ctx do
    ctx.project
    |> Ecto.Changeset.change(repo_full_name: "org/repo", installation_id: 1)
    |> Repo.update!()

    {:ok, _} =
      Ravix.Plans.create(ctx.user, ctx.project.id, %{
        "title" => "Mixed work",
        "items" => [
          %{"id" => "finished", "title" => "Finished item"},
          %{"id" => "active", "title" => "Active item"}
        ]
      })

    for id <- ["finished", "active"] do
      Ravix.Plans.Item
      |> Repo.get!(id)
      |> Ecto.Changeset.change(track_id: ctx.track.id)
      |> Repo.update!()
    end

    stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)

    stub(Ravix.GitHub, :plan_pulls, fn _, _, _ ->
      {:ok,
       %{
         complete: true,
         pulls: [
           %{state: :merged, number: 1, plan_item_ids: ["finished"]},
           %{state: :open, number: 2, plan_item_ids: ["active"]}
         ]
       }}
    end)

    reject(Ravix.GitHub, :pull_for_track, 5)
    enqueue(ctx, "Continue remaining work")
    client = provider(delivery([stage(1)]))
    Server.tick(ctx.server)
    assert [prompt] = prompts(client)
    assert prompt =~ "Finished item (finished) — reported status: done"
    assert prompt =~ "Active item (active) — reported status: in review"
    assert prompt =~ "Skip items confirmed done"
  end

  defp server do
    pid =
      start_supervised!(
        Supervisor.child_spec({Server, name: nil, interval: false}, id: make_ref())
      )

    Sandbox.allow(Repo, self(), pid)

    for mod <- [Fountain, Ravix.Projects, Ravix.Previews, Ravix.Config, Ravix.GitHub],
        do: allow(mod, self(), pid)

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

  defp accepted, do: {202, [], %{data: %{ok: true}}}

  defp delivery(events, response \\ accepted(), cursor \\ 0) do
    [idle(), page(events, cursor), post(response)]
  end

  defp post(response),
    do: {%{method: "POST", path: "/api/conversations/reset-thread/prompts"}, response}

  defp page(events, cursor, meta \\ %{}) do
    {event_request(cursor), {200, [], %{data: events, meta: meta}}}
  end

  defp event_request(cursor) do
    %{
      method: "GET",
      path: "/api/conversations/reset-thread/events",
      query: %{after: to_string(cursor), limit: "1000"}
    }
  end

  defp event_cursors(client) do
    client
    |> FakeTransport.calls()
    |> Enum.filter(&String.ends_with?(&1.path, "/events"))
    |> Enum.map(& &1.query["after"])
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

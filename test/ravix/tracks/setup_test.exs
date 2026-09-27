defmodule Ravix.Tracks.SetupTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.{Fountain, PromptQueue, Tracks}
  alias Ravix.Fountain.{Client, Error, Shapes}
  alias Ravix.PromptQueue.{Item, Server}
  alias Ravix.PromptQueue.Store, as: QueueStore
  alias Ravix.Tooling.{OAuth, Tasks, Wait}
  alias Ravix.Tracks.{Setup, Thread, Track}
  import Ravix.ToolingFixture

  setup do
    user = insert_user()
    project = insert_project(user: user, repo_full_name: nil, installation_id: nil, vault_id: nil)

    track =
      insert_track(
        project: project,
        conversation_id: "setup",
        setup_state: "running",
        setup_attempts: 1,
        setup_started_at: DateTime.utc_now()
      )

    client = Client.new("https://fountain.test", "test-key")

    test = self()
    stub(Fountain, :client, fn -> client end)
    stub(Ravix.Projects, :prepare_machine, fn _, _ -> :ok end)
    stub(Ravix.Previews, :prepare_agent_preview, fn _ -> "" end)

    stub(Fountain, :get_conversation, fn _, id ->
      {:ok, Shapes.conversation(%{"id" => id, "status" => "idle", "sandbox_id" => "sandbox"})}
    end)

    stub(Fountain, :events, fn _, _ -> {:ok, []} end)

    stub(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: nil, has_more: false}}
    end)

    stub(Fountain, :listing, fn _, "sandbox", path ->
      {:ok, %{"path" => path, "entries" => [%{"name" => ".git"}]}}
    end)

    stub(Fountain, :prompt, fn _, id, text, _, opts ->
      send(test, {:prompt, id, text, opts[:client_request_id]})
      :ok
    end)

    server = server()
    %{user: user, project: project, track: track, client: client, server: server}
  end

  test "MCP retries failed setup, names recovery tools, and enforces grants and ownership", ctx do
    persist(ctx.track, setup_state: "failed", setup_error: "opening refused")
    {principal, _, _} = principal(ctx.user)
    assert Setup.failure_message() =~ "retry_setup"
    assert Setup.failure_message() =~ "retry_task"
    other = insert_track(setup_state: "failed")

    assert {:error, :not_found} =
             Ravix.Tooling.call(principal, "retry_setup", %{"track_id" => other.id})

    assert {:ok, %{retried: true}} =
             Ravix.Tooling.call(principal, "retry_setup", %{"track_id" => ctx.track.id})

    assert row(ctx.track).setup_state == "running"
    assert_received {:prompt, "setup", _, _}

    assert {:error, {:conflict, "setup_pending", _}} =
             Ravix.Tooling.call(principal, "retry_setup", %{"track_id" => ctx.track.id})

    OAuth.disconnect(ctx.user, principal.grant.id)
    persist(row(ctx.track), setup_state: "failed")

    assert {:error, :unauthenticated} =
             Ravix.Tooling.call(principal, "retry_setup", %{"track_id" => ctx.track.id})

    assert row(ctx.track).setup_state == "failed"
    refute_received {:prompt, _, _, _}
  end

  defp server do
    pid =
      start_supervised!(
        Supervisor.child_spec({Server, name: nil, interval: false},
          id: make_ref()
        )
      )

    Sandbox.allow(Repo, self(), pid)
    for mod <- [Fountain, Ravix.Projects, Ravix.Previews], do: allow(mod, self(), pid)
    pid
  end

  defp turn_status(track, status) do
    stub(Fountain, :turns, fn _, _ ->
      row = Repo.get!(Track, track.id)

      {:ok,
       [
         Shapes.turn(%{
           "id" => "opening",
           "prompt" => "[ravix] Open this track. Make its working directory, then stop.",
           "status" => status,
           "client_request_id" => row.setup_request_id
         })
       ]}
    end)
  end

  defp persist(track, attrs), do: track |> Ecto.Changeset.change(attrs) |> Repo.update!()
  defp row(track), do: Repo.get!(Track, track.id)

  defp due(track),
    do: persist(row(track), setup_retry_at: DateTime.add(DateTime.utc_now(), -1, :second))

  defp queue(ctx, text \\ "user work") do
    {:ok, item} =
      Tracks.prompt(ctx.user, ctx.track.id, %{prompt: text, request_id: Ecto.UUID.generate()})

    item
  end

  test "completed upstream opening with exhausted model retries records setup failure and backs off",
       ctx do
    ctx.project |> Ecto.Changeset.change(runtime: "codex") |> Repo.update!()
    turn_status(ctx.track, "completed")
    stub(Fountain, :events, fn _, _ -> {:ok, Ravix.AgentOutageFixture.events("opening")} end)

    stub(Fountain, :listing, fn _, _, _ ->
      flunk("an outage must not verify an old worktree")
    end)

    Setup.advance(ctx.client, ctx.track.id)
    failed = row(ctx.track)
    assert failed.setup_state == "retry"
    assert failed.setup_error_code == "agent_provider_unreachable"
    assert failed.setup_error =~ "Codex couldn't reach OpenAI"
    assert DateTime.diff(failed.setup_retry_at, DateTime.utc_now()) >= 59

    assert %{
             stage: "setup",
             state: "failed",
             code: "agent_provider_unreachable",
             reason: reason
           } =
             Repo.get_by!(Ravix.Tracks.TurnFailure,
               conversation_id: "setup",
               turn_id: "opening",
               stage: "setup"
             )

    assert reason == failed.setup_error
    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_attempts == 1
    refute_received {:prompt, _, _, _}
  end

  test "failed opening retries with backoff, and a different worker delivers only after verification",
       ctx do
    item = queue(ctx)
    turn_status(ctx.track, "failed")
    assert :ok = Server.tick(ctx.server)
    assert row(ctx.track).setup_state == "retry"
    assert QueueStore.get(item.id).status == :queued
    refute_received {:prompt, _, _, _}
    Server.tick(ctx.server)
    refute_received {:prompt, _, _, _}

    due(ctx.track)
    other = server()
    Server.tick(other)
    assert_receive {:prompt, "setup", "[ravix] Open this track" <> _, request_id}
    assert is_binary(request_id)
    assert row(ctx.track).setup_attempts == 2
    assert QueueStore.get(item.id).status == :queued

    turn_status(ctx.track, "completed")
    due(ctx.track)
    Server.tick(other)
    assert row(ctx.track).setup_state == "ready"
    assert row(ctx.track).opened_at
    assert_receive {:prompt, "setup", "user work", _}
    assert QueueStore.get(item.id).status == :sent
  end

  test "exhaustion fails all queued prompts and MCP tasks, retaining bodies for explicit retry",
       ctx do
    {principal, _, _} = principal(ctx.user)
    {:ok, task} = Tasks.send(principal, ctx.track.id, "MCP work", "setup-task")
    item = queue(ctx)
    turn_status(ctx.track, "failed")

    for attempt <- 1..3 do
      due(ctx.track)
      Server.tick(ctx.server)
      assert row(ctx.track).setup_attempts == attempt

      if attempt < 3 do
        due(ctx.track)
        Server.tick(ctx.server)
        assert_receive {:prompt, _, "[ravix] Open this track" <> _, _}
      end
    end

    assert row(ctx.track).setup_state == "failed"

    assert %{status: :failed, error: "Track setup failed." <> _, body: %{"prompt" => "user work"}} =
             QueueStore.get(item.id)

    assert {:ok, %{state: "TASK_STATE_FAILED", status_message: reason}} =
             Tasks.get(principal, task.id)

    assert reason =~ "Track setup failed."
    assert reason =~ "retry_setup"
    assert reason =~ "retry_task"

    assert {:ok, %{changed: [changed_id], tasks: [reported]}} =
             Wait.wait(principal, %{
               "task_ids" => [task.id],
               "timeout_ms" => 0,
               "since" => %{task.id => "TASK_STATE_SUBMITTED"}
             })

    assert changed_id == task.id
    assert reported.status.state == "TASK_STATE_FAILED"
    assert hd(reported.status.message.parts).text =~ "Track setup failed."

    refute_received {:prompt, _, "user work", _}
    refute_received {:prompt, _, "MCP work", _}

    assert :ok = Tracks.retry(ctx.user, ctx.track.id)
    assert row(ctx.track).setup_attempts == 1
    assert_receive {:prompt, _, "[ravix] Open this track" <> _, _}
    turn_status(ctx.track, "completed")
    due(ctx.track)
    Server.tick(ctx.server)
    assert row(ctx.track).setup_state == "ready"
    assert QueueStore.get(item.id).status == :failed
    assert :ok = PromptQueue.retry(ctx.user, ctx.track.id, item.id)
  end

  test "completed status without the worktree cannot release the queue", ctx do
    item = queue(ctx)
    turn_status(ctx.track, "completed")
    stub(Fountain, :listing, fn _, _, _ -> {:error, %Error{status: 404}} end)
    Server.tick(ctx.server)
    assert row(ctx.track).setup_state == "retry"
    assert row(ctx.track).setup_error =~ "without creating"
    refute QueueStore.claim(item.id)
    refute_received {:prompt, _, _, _}
  end

  test "a plain directory is insufficient for a repository worktree", ctx do
    persist(ctx.track, setup_state: "running")
    ctx.project |> Ecto.Changeset.change(repo_full_name: "owner/repo") |> Repo.update!()
    turn_status(ctx.track, "completed")
    stub(Fountain, :listing, fn _, _, path -> {:ok, %{"path" => path, "entries" => []}} end)
    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "retry"
  end

  test "provider outages retain the gate without spending retries", ctx do
    turn_status(ctx.track, "completed")
    stub(Fountain, :listing, fn _, _, _ -> {:error, %Error{status: 503}} end)
    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "running"
    assert row(ctx.track).setup_attempts == 1
    refute row(ctx.track).setup_lease
  end

  test "an ambiguous idle turn times out, but does not count an unrelated completed turn", ctx do
    persist(ctx.track,
      setup_started_at: DateTime.add(DateTime.utc_now(), -601, :second),
      setup_request_id: "ours"
    )

    stub(Fountain, :turns, fn _, _ ->
      {:ok,
       [
         Shapes.turn(%{
           "id" => "other",
           "status" => "completed",
           "client_request_id" => "not-ours"
         })
       ]}
    end)

    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "retry"
    assert row(ctx.track).setup_error =~ "could not be confirmed"
  end

  test "crash after sending is reconciled by the persisted request id", ctx do
    persist(ctx.track, setup_state: "pending", setup_attempts: 0)
    stub(Fountain, :prompt, fn _, _, _, _, _ -> raise "lost response" end)
    assert_raise RuntimeError, "lost response", fn -> Setup.advance(ctx.client, ctx.track.id) end
    assert row(ctx.track).setup_request_id
    assert row(ctx.track).setup_state == "running"
    turn_status(ctx.track, "completed")
    due(ctx.track)
    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "ready"
    assert row(ctx.track).setup_attempts == 1
  end

  test "leases survive worker replacement and stale generations cannot settle setup", ctx do
    claimed = Tracks.Store.claim_setup(ctx.track.id)
    assert claimed.setup_lease
    assert is_nil(Tracks.Store.claim_setup(ctx.track.id))
    Server.tick(server())
    assert row(ctx.track).setup_state == "running"
    persist(row(ctx.track), setup_lease_until: DateTime.add(DateTime.utc_now(), -1, :second))
    replacement = Tracks.Store.claim_setup(ctx.track.id)
    refute replacement.setup_lease == claimed.setup_lease
    refute Tracks.Store.update_setup(claimed, setup_state: "ready")
    assert Tracks.Store.update_setup(replacement, setup_state: "retry")
  end

  test "Wake / retry still wakes an already verified track", ctx do
    persist(ctx.track, setup_state: "ready", opened_at: DateTime.utc_now())

    expect(Fountain, :prompt, fn _, "setup", prompt ->
      assert prompt =~ "[ravix] Open this track"
      :ok
    end)

    assert :ok = Tracks.retry(ctx.user, ctx.track.id)
    assert row(ctx.track).setup_state == "ready"
    assert row(ctx.track).setup_attempts == 1
  end

  test "credential refusal ends setup immediately with a reconnect instruction", ctx do
    persist(ctx.track, setup_state: "pending", setup_attempts: 0)
    item = queue(ctx)

    expect(Fountain, :prompt, fn _, _, _, _, _ ->
      {:error, %Error{status: 422, code: "inference_credential_unusable"}}
    end)

    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "failed"
    assert row(ctx.track).setup_error =~ "connection isn't working"
    assert row(ctx.track).setup_error =~ "account settings"
    refute row(ctx.track).setup_error =~ "inference_credential_unusable"
    assert QueueStore.get(item.id).status == :failed
    due(ctx.track)
    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_attempts == 1
  end

  test "a refused wake is returned to its caller", ctx do
    persist(ctx.track, setup_state: "ready", opened_at: DateTime.utc_now())
    refusal = %Error{status: 409, code: "sandbox_at_capacity"}
    expect(Fountain, :prompt, fn _, _, _ -> {:error, refusal} end)
    assert {:error, ^refusal} = Tracks.retry(ctx.user, ctx.track.id)
  end

  test "wake addresses the selected thread and rejects another track's thread", ctx do
    persist(ctx.track, setup_state: "ready")

    thread =
      %Thread{}
      |> Thread.changeset(%{
        track_id: ctx.track.id,
        conversation_id: "selected",
        title: "Other"
      })
      |> Repo.insert!()

    expect(Fountain, :prompt, fn _, "selected", _ -> :ok end)
    assert :ok = Tracks.retry(ctx.user, ctx.track.id, thread.id)
    other = insert_track(project: ctx.project)
    assert {:error, :not_found} = Tracks.retry(ctx.user, other.id, thread.id)
    assert {:error, :not_found} = Tracks.retry(insert_user(), ctx.track.id, thread.id)
  end

  test "pending setup rejects wake without resetting its budget", ctx do
    for state <- ["pending", "running", "retry"] do
      persist(ctx.track, setup_state: state)
      assert {:error, {:conflict, "setup_pending", _}} = Tracks.retry(ctx.user, ctx.track.id)
      assert row(ctx.track).setup_attempts == 1
    end

    refute_received {:prompt, _, _, _}
  end

  test "capacity rejection waits without exhausting the setup budget", ctx do
    persist(ctx.track, setup_state: "pending", setup_attempts: 0)

    stub(Fountain, :prompt, fn _, _, _, _, _ ->
      {:error, %Error{status: 409, code: "sandbox_at_capacity"}}
    end)

    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "retry"
    assert row(ctx.track).setup_attempts == 0

    assert row(ctx.track).setup_error ==
             "The machine is busy with other turns; trying again shortly."

    assert DateTime.compare(row(ctx.track).setup_retry_at, DateTime.utc_now()) == :gt
  end

  test "the runtime's human reason is recorded and unauthorized retry cannot reset it", ctx do
    turn_status(ctx.track, "failed")

    stub(Fountain, :events, fn _, _ ->
      {:ok,
       [
         %{
           "kind" => "stage",
           "stage" => "turn",
           "state" => "failed",
           "data" => Jason.encode!(%{reason: "The adapter crashed during initialization."})
         }
       ]}
    end)

    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_error =~ "adapter crashed"
    assert {:error, :not_found} = Tracks.retry(insert_user(), ctx.track.id)
    assert row(ctx.track).setup_attempts == 1
  end

  test "a delayed exhaustion handler cannot fail prompts after setup recovers", ctx do
    item = queue(ctx)
    persist(ctx.track, setup_state: "ready")
    QueueStore.fail_setup(ctx.track.id, Setup.failure_message())
    assert QueueStore.get(item.id).status == :queued
  end

  test "the database also refuses an old instance's ungated claim", ctx do
    item = queue(ctx)

    assert {0, _} =
             Repo.update_all(from(p in Item, where: p.id == ^item.id),
               set: [status: :sending]
             )

    assert QueueStore.get(item.id).status == :queued
    persist(ctx.track, setup_state: "ready")

    assert {1, _} =
             Repo.update_all(from(p in Item, where: p.id == ^item.id),
               set: [status: :sending]
             )
  end

  test "running reconciliation is throttled across workers and grows to thirty seconds", ctx do
    turn_status(ctx.track, "running")

    expect(Fountain, :get_conversation, 2, fn _, id ->
      {:ok, Shapes.conversation(%{"id" => id, "status" => "running"})}
    end)

    Server.tick(ctx.server)
    first = row(ctx.track)
    assert DateTime.diff(first.setup_retry_at, DateTime.utc_now()) in 4..5
    refute ctx.track.id in Tracks.Store.pending_setups()
    refute Tracks.Store.claim_setup(ctx.track.id)
    other = server()
    Server.tick(other)
    Setup.advance(ctx.client, ctx.track.id)
    refute :sys.get_state(other).waiting?

    persist(first, setup_started_at: DateTime.add(DateTime.utc_now(), -300, :second))
    due(ctx.track)
    assert ctx.track.id in Tracks.Store.pending_setups()
    Server.tick(other)
    assert DateTime.diff(row(ctx.track).setup_retry_at, DateTime.utc_now()) in 29..30
  end

  test "legacy opened worktree is ready without matching opening history or a new prompt", ctx do
    persist(ctx.track,
      setup_state: "pending",
      opened_at: DateTime.utc_now(),
      created_at: DateTime.add(DateTime.utc_now(), -86_400, :second),
      setup_request_id: nil
    )

    ctx.project |> Ecto.Changeset.change(repo_full_name: "owner/repo") |> Repo.update!()
    stub(Fountain, :turns, fn _, _ -> {:ok, []} end)
    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "ready"
    refute_received {:prompt, _, _, _}
  end

  test "legacy listing outages hold setup and missing worktrees allow repair", ctx do
    persist(ctx.track, setup_state: "pending", opened_at: DateTime.utc_now())
    stub(Fountain, :turns, fn _, _ -> {:ok, []} end)
    stub(Fountain, :listing, fn _, _, _ -> {:error, %Error{status: 503}} end)
    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "running"
    refute_received {:prompt, _, _, _}

    due(ctx.track)
    stub(Fountain, :listing, fn _, _, _ -> {:error, %Error{status: 404}} end)
    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "retry"
  end

  test "legacy accepted tracks are verified and closed tracks never retry", ctx do
    persist(ctx.track, setup_state: "pending", opened_at: DateTime.utc_now())
    turn_status(ctx.track, "completed")
    due(ctx.track)
    Setup.advance(ctx.client, ctx.track.id)
    assert row(ctx.track).setup_state == "ready"
    persist(row(ctx.track), setup_state: "failed", closed_at: DateTime.utc_now())
    refute Tracks.Store.retry_setup(ctx.track.id)
    assert is_nil(Tracks.Store.claim_setup(ctx.track.id))
  end
end

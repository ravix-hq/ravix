defmodule Ravix.TrackMaintenanceTest do
  use Ravix.DataCase, async: true
  import Mimic
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Fountain.Launch
  alias Ravix.Projects
  alias Ravix.Projects.Project
  alias Ravix.Projects.RuntimeAgents
  alias Ravix.Tracks
  alias Ravix.Tracks.Sandbox
  alias Ravix.Tracks.Sandbox.Maintenance
  alias Ravix.Tracks.Sandbox.Store
  setup :verify_on_exit!

  setup do
    owner = insert_user(credential_set_id: "owner-set")

    project =
      insert_project(
        user: owner,
        runtime: "claude",
        credential_set_id: "owner-set",
        model: "claude-model",
        repo_full_name: nil,
        installation_id: nil
      )

    stub(Ravix.Config, :dedicated_opens_enabled?, fn user -> user.id == owner.id end)
    stub(Ravix.Config, :dedicated_rollout?, fn -> true end)
    %{owner: owner, project: project}
  end

  defp provider(routes) do
    client = FakeTransport.client(routes)
    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  test "an old writer's runtime switch keeps the nullable home fallback usable with the cohort off",
       ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> false end)
    stub(Ravix.Config, :dedicated_rollout?, fn -> false end)
    assert is_nil(ctx.project.home_runtime)
    ctx.project |> Ecto.Changeset.change(runtime: "codex", model: "codex-model") |> Repo.update!()
    project = Projects.Store.get_project(ctx.project.id)
    client = provider([])
    stub(Ravix.Accounts.Inference, :usable?, fn _, "codex", _ -> {:ok, true} end)

    assert is_nil(project.home_runtime)
    assert Project.home_runtime(project) == "codex"
    assert {:ok, "codex"} = RuntimeAgents.home_runtime(project, client, nil)

    assert {:ok, %{runtime: "codex", agent_id: agent_id}} =
             Tracks.Runtime.select(ctx.owner, project, client, %{})

    assert agent_id == project.agent_id
    assert FakeTransport.calls(client) == []
  end

  test "maintenance retirement exhausts retries and releases its fence", ctx do
    track = insert_track(project: ctx.project, conversation_id: nil)
    assert {:ok, :ok} = Store.retire_shared_tracks(ctx.project)
    [op] = Store.operations(track.id)
    assert op.resource_ids["maintenance"]

    client =
      provider(
        List.duplicate(
          {%{method: "GET", path: "/api/sandboxes"}, {503, [], %{error: "unavailable"}}},
          5
        )
      )

    for attempt <- 1..5 do
      if attempt == 5 do
        assert {:error, {:conflict, "machine_cleanup_failed", _}} =
                 Projects.Deletion.retire_shared(ctx.project, client)
      else
        Sandbox.advance(client, op.id)
      end

      current = Store.get_operation(op.id)
      assert current.attempts == attempt
      if attempt < 5, do: Store.update_operation(current, %{retry_at: nil})
    end

    assert %{
             phase: "failed",
             completed_at: %DateTime{},
             error: %{"code" => "sandbox_cleanup_pending"}
           } =
             Store.get_operation(op.id)

    refute Projects.Store.get_project(ctx.project.id).shared_machine_retiring
    refute op.id in Store.pending()
  end

  test "defaults keep the home identity and existing threads, including old rows", ctx do
    track = insert_track(project: ctx.project, sandbox_layout: :dedicated, sandbox_state: :ready)
    stub(Ravix.Accounts.Inference, :usable?, fn _, "codex", _ -> {:ok, true} end)

    client =
      provider([
        {%{method: "GET", path: "/api/catalog"},
         {200, [], %{data: %{runtimes: ["claude", "codex"], models: %{codex: ["codex-model"]}}}}}
      ])

    assert {:ok, %{rev: 2}} =
             Projects.update_settings(ctx.owner, ctx.project.id, %{
               runtime: "codex",
               model: "codex-model"
             })

    project = Projects.Store.get_project(ctx.project.id)
    assert project.runtime == "codex"
    assert Project.home_runtime(project) == "claude"
    assert project.agent_id == ctx.project.agent_id
    assert %{runtime: "claude", model: "claude-model"} = Tracks.Store.thread(track.id)
    assert is_nil(Tracks.Store.get_track(track.id).closed_at)

    assert {:ok, id} =
             RuntimeAgents.ensure(project, client, "claude", "claude-model", isolated: true)

    assert id == ctx.project.agent_id
    assert Enum.all?(FakeTransport.calls(client), &(&1.method == "GET"))
    assert Store.operations(track.id) == []
  end

  test "mixed projects retire only shared tracks and never delete runtime agents", ctx do
    shared = insert_track(project: ctx.project, conversation_id: nil)

    sibling =
      insert_track(
        project: ctx.project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_id: "sibling",
        vault_id: "sibling-vault"
      )

    stub(Ravix.Accounts.Inference, :usable?, fn _, _, _ -> {:ok, true} end)

    client =
      provider([
        {%{method: "GET", path: "/api/catalog"},
         {200, [], %{data: %{runtimes: ["codex"], models: %{codex: ["codex-model"]}}}}},
        {%{method: "GET", path: "/api/sandboxes"},
         {200, [],
          %{
            data: [
              %{
                id: "shared",
                agent_id: ctx.project.agent_id,
                environment_id: ctx.project.environment_id,
                vault_id: ctx.project.vault_id
              }
            ]
          }}},
        {%{method: "DELETE", path: "/api/sandboxes/shared"}, {204, [], ""}},
        {%{method: "GET", path: "/api/sandboxes/shared"},
         {404, [], %{error: "sandbox_not_found"}}}
      ])

    assert {:ok, _} =
             Projects.update_settings(ctx.owner, ctx.project.id, %{
               runtime: "codex",
               model: "codex-model",
               rebuild: true
             })

    assert Tracks.Store.get_track(shared.id).closed_at
    assert Tracks.Store.get_track(sibling.id) == sibling
    assert Store.operations(sibling.id) == []
    assert [%{completed_at: %DateTime{}}] = Store.operations(shared.id)
    refute Enum.any?(FakeTransport.calls(client), &String.starts_with?(&1.path, "/api/agents"))
    assert Projects.Store.get_project(ctx.project.id).home_runtime == "claude"
  end

  test "selected runtime health never leaks a sibling's disconnected banner", ctx do
    track = insert_track(project: ctx.project, sandbox_layout: :dedicated, sandbox_state: :ready)
    Tracks.Store.set_thread_model(track.id, "claude-model")

    {:ok, second} =
      Tracks.Store.create_thread(%{
        track_id: track.id,
        runtime: "codex",
        model: "codex-model",
        title: "Other"
      })

    stub(Ravix.Accounts.Inference, :usable?, fn _, runtime, _ -> {:ok, runtime == "claude"} end)

    assert {:ok, %{runtime: "codex", usable?: false, scope: :thread}} =
             Tracks.agent_health(ctx.owner, track.id, second.id)

    assert {:ok, %{runtime: "claude", usable?: true}} =
             Tracks.agent_health(ctx.owner, track.id, track.id)

    assert {:error, :not_found} = Tracks.agent_health(insert_user(), track.id, second.id)
    another = insert_track(project: ctx.project)
    assert {:error, :not_found} = Tracks.agent_health(ctx.owner, another.id, second.id)
  end

  test "flag-off default runtime changes still require the legacy rebuild", ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> false end)
    stub(Ravix.Config, :dedicated_rollout?, fn -> false end)
    stub(Ravix.Accounts.Inference, :usable?, fn _, _, _ -> {:ok, true} end)

    client =
      provider([
        {%{method: "GET", path: "/api/catalog"},
         {200, [], %{data: %{runtimes: ["codex"], models: %{codex: ["codex-model"]}}}}}
      ])

    assert {:error, {:unprocessable, "rebuild_required", _}} =
             Projects.update_settings(ctx.owner, ctx.project.id, %{
               runtime: "codex",
               model: "codex-model"
             })

    assert Projects.Store.get_project(ctx.project.id).runtime == "claude"
    refute Enum.any?(FakeTransport.calls(client), &(&1.method != "GET"))
    assert Projects.Store.pending_deletions() == []
  end

  test "adoption names the owner's set on this launch without changing a sibling agent", ctx do
    launch = %Launch{
      agent_id: ctx.project.agent_id,
      environment_id: ctx.project.environment_id,
      vault_id: "one-track",
      sandbox_id: "one-disk",
      channel_id: "one-thread",
      title: nil,
      prompt: nil
    }

    adopted = Maintenance.adopt(launch, ctx.project)
    assert adopted.inference_credential_id == "owner-set"
    assert adopted.vault_id == "one-track"

    client =
      provider([
        {%{method: "POST", path: "/api/conversations"},
         {201, [], %{data: %{id: "new", sandbox_id: "one-disk"}}}}
      ])

    assert {:ok, _} = Ravix.Fountain.create_conversation(client, adopted)
    [call] = FakeTransport.calls(client)
    assert call.body["inference_credential_id"] == "owner-set"

    assert Projects.Store.get_project(ctx.project.id).credential_set_id ==
             ctx.project.credential_set_id
  end

  test "adopting a different source expands only the agent allowlist, leaving sibling sessions pinned",
       ctx do
    project = Repo.update!(Ecto.Changeset.change(ctx.project, credential_set_id: "previous-set"))

    client =
      provider([
        {%{method: "GET", path: "/api/agents/#{project.agent_id}"},
         {200, [],
          %{
            data: %{
              inference_credential_id: "previous-set",
              allowed_inference_credential_ids: ["other-allowed"]
            }
          }}},
        {%{method: "PUT", path: "/api/agents/#{project.agent_id}"},
         {200, [], %{data: %{id: project.agent_id}}}}
      ])

    assert {:ok, _} = RuntimeAgents.ensure(project, client, "claude", nil, isolated: true)
    update = Enum.find(FakeTransport.calls(client), &(&1.method == "PUT"))
    assert update.body == %{"allowed_inference_credential_ids" => ["other-allowed", "owner-set"]}
    assert Projects.Store.get_project(project.id).credential_set_id == "previous-set"
  end

  test "token failure is retryable and writes only the selected track's copy", ctx do
    project =
      Repo.update!(
        Ecto.Changeset.change(ctx.project, repo_full_name: "owner/repo", installation_id: 42)
      )

    one =
      insert_track(
        project: project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        vault_id: "copy-one"
      )

    sibling =
      insert_track(
        project: project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        vault_id: "copy-two"
      )

    stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)
    expect(Ravix.GitHub, :mint_clone_token, 2, fn _, 42 -> {:ok, "fresh-fixture-token"} end)

    client =
      provider([
        {%{method: "POST", path: "/api/vaults/copy-one/secrets"},
         {503, [], %{error: "unavailable"}}},
        {%{method: "POST", path: "/api/vaults/copy-one/secrets"},
         {201, [], %{data: %{key: "RAVIX_CLONE_TOKEN"}}}}
      ])

    assert {:error, _} = Maintenance.prepare(client, one, project)
    assert :ok = Maintenance.prepare(client, one, project)
    assert Tracks.Store.get_track(sibling.id) == sibling
    assert Enum.all?(FakeTransport.calls(client), &(&1.path == "/api/vaults/copy-one/secrets"))
  end

  test "credential revision recovers each connected thread on its own disk, retaining history",
       ctx do
    stub(Ravix.Accounts.Inference, :usable?, fn _, runtime, [fresh: true] ->
      {:ok, runtime == "claude"}
    end)

    track =
      insert_track(
        project: ctx.project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_id: "disk",
        vault_id: "copy",
        conversation_id: "old"
      )

    {:ok, codex} =
      Tracks.Store.create_thread(%{
        track_id: track.id,
        runtime: "codex",
        title: "Codex",
        conversation_id: "codex-old"
      })

    alias Ravix.Tracks.CredentialRecovery
    assert {:ok, _} = CredentialRecovery.reject(track, ctx.project, track.id)

    assert {:ok, _} =
             CredentialRecovery.reject(
               %{track | conversation_id: "codex-old"},
               ctx.project,
               codex.id
             )

    client =
      provider([
        {%{method: "POST", path: "/api/conversations"},
         {201, [], %{data: %{id: "replacement", sandbox_id: "disk"}}}}
      ])

    assert :rebound = CredentialRecovery.prepare(client, track, ctx.project, track.id)
    assert :waiting = CredentialRecovery.prepare(client, track, ctx.project, codex.id)
    thread = Tracks.Store.thread(track.id)
    assert thread.previous_conversation_ids == ["old"]
    assert thread.conversation_id == "replacement"
    assert thread.recovery_context_pending
    assert Tracks.Store.thread(track.id, codex.id).conversation_id == "codex-old"
    assert Store.get_track(track.id).sandbox_id == "disk"
    [call] = FakeTransport.calls(client)
    assert call.body["sandbox_id"] == "disk"
    assert call.body["vault_id"] == "copy"
    assert call.body["inference_credential_id"] == "owner-set"
    Tracks.Store.credential_context_delivered(track.id, "old")
    assert Tracks.Store.thread(track.id).recovery_context_pending
    Tracks.Store.credential_context_delivered(track.id, "replacement")
    refute Tracks.Store.thread(track.id).recovery_context_pending
  end

  test "lost replacement responses reconcile by persisted identity without a second allocation",
       ctx do
    alias Ravix.Tracks.CredentialRecovery
    stub(Ravix.Accounts.Inference, :usable?, fn _, _, _ -> {:ok, true} end)

    track =
      insert_track(
        project: ctx.project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_id: "disk",
        vault_id: "copy",
        conversation_id: "old"
      )

    {:ok, thread} = CredentialRecovery.reject(track, ctx.project, track.id)
    channel = thread.credential_recovery["channel"]

    client =
      provider([
        {%{method: "POST", path: "/api/conversations"}, {503, [], %{error: "unavailable"}}},
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
        {%{method: "GET", path: "/api/conversations"},
         {200, [], %{data: [%{id: "recovered", sandbox_id: "disk", channel_id: channel}]}}}
      ])

    assert :waiting = CredentialRecovery.prepare(client, track, ctx.project, track.id)
    assert :waiting = CredentialRecovery.prepare(client, track, ctx.project, track.id)
    assert :rebound = CredentialRecovery.prepare(client, track, ctx.project, track.id)
    assert Tracks.Store.thread(track.id).conversation_id == "recovered"
    assert Enum.count(FakeTransport.calls(client), &(&1.method == "POST")) == 1
  end

  test "a rebuilt generation rejects a stale replacement binding", ctx do
    track =
      insert_track(
        project: ctx.project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_id: "disk",
        conversation_id: "old"
      )

    {:ok, thread} = Tracks.Store.recover_credentials(track, track.id)
    {:ok, attempted} = Tracks.Store.attempt_credential_recovery(thread)
    assert {:error, :stale_recovery} = Tracks.Store.attempt_credential_recovery(thread)
    Repo.update!(Ecto.Changeset.change(track, sandbox_generation: track.sandbox_generation + 1))

    assert {:error, :stale_generation} =
             Tracks.Store.bind_credential_recovery(track, attempted, "wrong")

    assert Tracks.Store.thread(track.id).conversation_id == "old"
  end

  test "a stale open cannot persist intent after project deletion reserves the project", ctx do
    assert {:ok, :ok} = Projects.Store.request_deletion(ctx.project)

    # The project fence is checked before reading the prepared opening plan or allocating resources.
    assert {:error, :not_found} = Store.create(nil, nil, ctx.project)
    assert {:error, :retiring} = Projects.Store.reserve_runtime(ctx.project.id, "codex")
    assert Tracks.Store.tracks_of(ctx.project.id, :all) == []
  end

  test "deletion persists closes, waits for cleanup, and retries template failures", ctx do
    a =
      insert_track(
        project: ctx.project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_id: "a",
        vault_id: "va",
        conversation_id: nil
      )

    b =
      insert_track(
        project: ctx.project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_id: "b",
        vault_id: "vb",
        conversation_id: nil
      )

    client = provider([])
    assert :ok = Projects.destroy(ctx.owner, ctx.project.id)
    assert FakeTransport.calls(client) == []
    assert Projects.Store.get_project(ctx.project.id).deletion_requested_at
    refute Projects.Store.get_project(ctx.project.id).archived_at
    assert {:error, :not_found} = Tracks.get(ctx.owner, a.id)
    member = insert_user()
    guest = insert_user()
    insert_project_member(ctx.project, member)
    insert_track_member(a, guest)

    for user <- [ctx.owner, member, guest] do
      assert {:error, :not_found} = Projects.get(user, ctx.project.id)
      assert Projects.list(user) == []
    end

    assert Enum.all?([a, b], &(Store.get_track(&1.id).sandbox_state == :closing))
    Projects.Deletion.reconcile(client)
    assert FakeTransport.calls(client) == []

    for {track, disk, vault} <- [{a, "a", "va"}, {b, "b", "vb"}] do
      [op] = Store.operations(track.id)

      cleanup =
        provider([
          {%{method: "DELETE", path: "/api/sandboxes/#{disk}"}, {204, [], ""}},
          {%{method: "GET", path: "/api/sandboxes/#{disk}"},
           {404, [], %{error: "sandbox_not_found"}}},
          {%{method: "DELETE", path: "/api/vaults/#{vault}"}, {204, [], ""}},
          {%{method: "GET", path: "/api/vaults/#{vault}"}, {404, [], %{error: "not_found"}}}
        ])

      Sandbox.advance(cleanup, op.id)
    end

    client =
      provider([
        {%{method: "DELETE", path: "/api/agents/#{ctx.project.agent_id}"},
         {503, [], %{error: "unavailable"}}},
        {%{method: "DELETE", path: "/api/agents/#{ctx.project.agent_id}"}, {204, [], ""}},
        {%{method: "DELETE", path: "/api/vaults/#{ctx.project.vault_id}"}, {204, [], ""}},
        {%{method: "DELETE", path: "/api/environments/#{ctx.project.environment_id}"},
         {204, [], ""}}
      ])

    Projects.Deletion.reconcile(client)
    refute Projects.Store.get_project(ctx.project.id).archived_at
    Projects.Deletion.reconcile(client)
    assert Projects.Store.get_project(ctx.project.id).archived_at
  end
end

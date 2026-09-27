defmodule Ravix.DedicatedLifecycleTest do
  use Ravix.DataCase, async: true
  import Mimic
  setup :verify_on_exit!
  alias Ravix.Accounts.Store, as: AccountsStore
  alias Ravix.Fountain.{Client, FakeTransport}
  alias Ravix.PromptQueue.Store, as: QueueStore
  alias Ravix.Tooling.Tasks
  alias Ravix.Tracks.Sandbox
  alias Ravix.Tracks.Sandbox.{Operation, Store}

  defp operation do
    project = insert_project(repo_full_name: nil, installation_id: nil)

    track =
      insert_track(
        project: project,
        sandbox_layout: :dedicated,
        conversation_id: nil,
        setup_state: "pending",
        opened_at: nil
      )

    {:ok, op} = Store.begin_operation(track.id, 0, :open)

    {:ok, op} =
      Store.update_operation(op, %{
        resource_ids: %{
          "source_vault_id" => project.vault_id,
          "agent_id" => project.agent_id,
          "environment_id" => project.environment_id,
          "channel_id" => "track-channel"
        }
      })

    {project, track, op}
  end

  test "uncertain creation is visible and never allocates again on retry" do
    {_project, track, op} = operation()
    {:ok, op} = Store.update_operation(op, %{phase: "launching"})

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/sandboxes"}, {200, [], %{data: []}}}
      ])

    Sandbox.advance(client, op.id)

    assert %{
             setup_state: "retry",
             setup_error_code: "sandbox_outcome_unknown",
             setup_error: message
           } = Store.get_track(track.id)

    assert message =~ "Ask the project owner"
    assert {:error, :pending} = Store.retry(Store.get_track(track.id))
    assert %{phase: "launching", completed_at: nil} = Store.get_operation(op.id)
    refute Enum.any?(FakeTransport.calls(client), &(&1.method == "POST"))
  end

  test "a rejected allocation deletes the copied secrets and retains actionable failure" do
    {project, track, op} = operation()
    user = AccountsStore.get_user(project.user_id)

    stub(Ravix.Fountain, :client, fn ->
      Client.new("https://fountain.test", "test-key")
    end)

    {principal, _, _} = Ravix.ToolingFixture.principal(user)

    {:ok, prompt} =
      Tasks.send(principal, track.id, "saved work", "allocation-failure")

    client =
      FakeTransport.client([
        {%{method: "POST", path: "/api/vaults/#{project.vault_id}/copy"},
         {201, [], %{data: %{id: "copy", name: "track", secret_count: 1}}}},
        {%{
           method: "POST",
           path: "/api/conversations",
           body: %{
             agent_id: project.agent_id,
             environment_id: project.environment_id,
             vault_id: "copy",
             sandbox_mode: "persistent",
             fresh: true,
             channel_id: "track-channel",
             title: track.title,
             prompt: Ravix.Spec.open_dedicated_prompt(project, track)
           }
         }, {422, [], %{error: "sandbox_creation_failed"}}},
        {%{method: "DELETE", path: "/api/vaults/copy"}, {204, [], ""}},
        {%{method: "GET", path: "/api/vaults/copy"}, {404, [], %{error: "not_found"}}}
      ])

    Sandbox.advance(client, op.id)
    assert %{phase: "failed", lease: nil} = Store.get_operation(op.id)

    assert %{vault_id: nil, setup_state: "failed", setup_error_code: "sandbox_creation_failed"} =
             Store.get_track(track.id)

    assert Store.pending() == []
    saved = QueueStore.get(prompt.id)
    assert saved.status == :failed
    assert saved.error_code == "sandbox_creation_failed"
    assert saved.error =~ "Retry setup, then retry this saved prompt."
    refute saved.error =~ "retry_setup"
    assert {:ok, task} = Tasks.get(principal, prompt.id)
    assert task.error_code == "sandbox_creation_failed"
    message = hd(Tasks.present(task).status.message.parts).text
    assert message =~ "retry_setup"
    assert message =~ "retry_task"
  end

  test "lost copy response recovers its named snapshot and never issues a second copy" do
    {_project, track, op} = operation()
    {:ok, op} = Store.update_operation(op, %{phase: "copying"})
    name = "ravix-track-#{track.id}-#{op.generation}"

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/vaults"}, {200, [], %{data: [%{id: "copy", name: name}]}}},
        {%{method: "POST", path: "/api/conversations"},
         {422, [], %{error: "sandbox_creation_failed"}}},
        {%{method: "DELETE", path: "/api/vaults/copy"}, {204, [], ""}},
        {%{method: "GET", path: "/api/vaults/copy"}, {404, [], %{error: "not_found"}}}
      ])

    Sandbox.advance(client, op.id)
    assert %{phase: "failed"} = Store.get_operation(op.id)
  end

  test "close during pending open prevents allocation; duplicate close is the same intent" do
    {_project, track, op} = operation()
    assert {:ok, :ok} = Store.request_close(track)
    assert {:ok, :ok} = Store.request_close(track)
    assert [_, %{action: :close}] = Store.operations(track.id)
    Sandbox.advance(FakeTransport.client([]), op.id)
    assert %{phase: "done", completed_at: %DateTime{}} = Store.get_operation(op.id)
    assert %{sandbox_state: :closing, closed_at: nil} = Store.get_track(track.id)
  end

  test "an expired lease cannot publish over a successor or a newer generation" do
    {_project, track, op} = operation()
    first = Store.claim(op.id)
    assert Store.claim(op.id) == nil

    Repo.update_all(from(o in Operation, where: o.id == ^op.id),
      set: [lease_until: DateTime.add(DateTime.utc_now(), -1)]
    )

    second = Store.claim(op.id)
    assert {:error, :lost_lease} = Store.progress(first, %{phase: "setup"}, sandbox_id: "late")
    assert {:ok, :ok} = Store.request_close(track)
    assert {:ok, _} = Store.progress(second, %{phase: "cleanup"}, sandbox_id: "late")
    assert Store.get_track(track.id).sandbox_id == nil
  end

  test "secret edits invalidate snapshots before I/O and preserve project secrets" do
    {project, track, _op} = operation()
    assert {:ok, 1} = Ravix.Projects.Store.begin_secret_change(project.id)
    assert Store.get_track(track.id).setup_error_code == "secrets_changed"
    assert Ravix.Projects.Store.live_project(project.id).secrets_pending
    assert {:error, :secrets_pending} = Ravix.Projects.Store.begin_secret_change(project.id)
    assert :ok = Ravix.Projects.Store.finish_secret_change(project.id, 1)
    refute Ravix.Projects.Store.live_project(project.id).secrets_pending
  end

  test "a lost allocation response is recovered by full identity, made ready, and closed durably" do
    {project, track, op} = operation()

    {:ok, op} =
      Store.update_operation(op, %{
        phase: "launching",
        resource_ids: Map.put(op.resource_ids, "vault_id", "copy")
      })

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/sandboxes"},
         {200, [],
          %{
            data: [
              %{
                id: "other",
                agent_id: project.agent_id,
                environment_id: project.environment_id,
                vault_id: "other-copy"
              },
              %{
                id: "disk",
                agent_id: project.agent_id,
                environment_id: project.environment_id,
                vault_id: "copy"
              }
            ]
          }}},
        {%{method: "GET", path: "/api/conversations"},
         {200, [], %{data: [%{id: "conversation", sandbox_id: "disk"}]}}},
        {%{method: "GET", path: "/api/conversations/conversation"},
         {200, [], %{data: %{id: "conversation", sandbox_id: "disk", status: "idle"}}}},
        {%{method: "GET", path: "/api/conversations/conversation/turns"},
         {200, [],
          %{data: [%{id: "turn", prompt: "[ravix] Open this track", status: "completed"}]}}},
        # Setup reads the opening turn's events for an agent outage (#285).
        {%{method: "GET", path: "/api/conversations/conversation/events"},
         {200, [], %{data: [], meta: %{has_more: false, next_cursor: nil}}}},
        {%{method: "GET", path: "/api/sandboxes/disk/files"},
         {200, [], %{data: %{path: track.workdir, entries: []}}}},
        {%{method: "POST", path: "/api/conversations/conversation/terminate"}, {200, [], %{}}},
        {%{method: "DELETE", path: "/api/sandboxes/disk"}, {204, [], ""}},
        {%{method: "GET", path: "/api/sandboxes/disk"},
         {200, [], %{data: %{id: "disk", status: "terminated"}}}},
        {%{method: "DELETE", path: "/api/vaults/copy"}, {204, [], ""}},
        {%{method: "GET", path: "/api/vaults/copy"}, {404, [], %{error: "not_found"}}}
      ])

    Sandbox.advance(client, op.id)

    assert %{sandbox_state: :ready, vault_id: "copy", setup_state: "ready"} =
             ready = Store.get_track(track.id)

    assert Store.get_operation(op.id).completed_at
    assert {:ok, :ok} = Store.request_close(ready)
    [_, close] = Store.operations(track.id)
    Sandbox.advance(client, close.id)
    assert %{sandbox_state: :terminated, closed_at: %DateTime{}} = Store.get_track(track.id)
    assert Store.get_operation(close.id).completed_at
    Sandbox.advance(client, close.id)

    refute Enum.any?(
             FakeTransport.calls(client),
             &(&1.path == "/api/conversations" and &1.method == "POST")
           )
  end

  test "close confirms terminal rows and explicit absence, and repeated close is idempotent" do
    for response <- [
          {200, [], %{data: %{id: "disk", status: "terminated"}}},
          {200, [], %{data: %{id: "disk", status: "failed"}}},
          {404, [], %{error: "sandbox_not_found"}},
          {410, [], %{error: "sandbox_gone"}}
        ] do
      disk = Ecto.UUID.generate()

      response =
        case response do
          {200, headers, %{data: data}} -> {200, headers, %{data: %{data | id: disk}}}
          other -> other
        end

      track = insert_track(sandbox_layout: :dedicated, sandbox_id: disk, conversation_id: nil)
      assert {:ok, :ok} = Store.request_close(track)
      [op] = Store.operations(track.id)

      client =
        FakeTransport.client([
          {%{method: "DELETE", path: "/api/sandboxes/#{disk}"},
           {422, [], %{error: "sandbox_not_resettable"}}},
          {%{method: "GET", path: "/api/sandboxes/#{disk}"}, response}
        ])

      Sandbox.advance(client, op.id)

      assert %{sandbox_state: :terminated, closed_at: %DateTime{}} =
               closed = Store.get_track(track.id)

      assert Store.get_operation(op.id).completed_at
      calls = FakeTransport.calls(client)
      assert {:ok, :ok} = Store.request_close(closed)
      Sandbox.advance(client, op.id)
      assert FakeTransport.calls(client) == calls
      assert length(Store.operations(track.id)) == 1
    end
  end

  test "a refused repeat DELETE must still confirm destruction before deleting the vault" do
    for response <- [
          {200, [], %{data: %{id: "disk", status: "ready"}}},
          {200, [], %{data: %{id: "disk", status: "deleting"}}},
          {404, [], %{error: "not_found"}},
          {503, [], %{error: "unavailable"}}
        ] do
      disk = Ecto.UUID.generate()

      response =
        case response do
          {200, headers, %{data: data}} -> {200, headers, %{data: %{data | id: disk}}}
          other -> other
        end

      track =
        insert_track(
          sandbox_layout: :dedicated,
          sandbox_id: disk,
          vault_id: "copy",
          conversation_id: nil
        )

      assert {:ok, :ok} = Store.request_close(track)
      [op] = Store.operations(track.id)

      client =
        FakeTransport.client([
          {%{method: "DELETE", path: "/api/sandboxes/#{disk}"},
           {422, [], %{error: "sandbox_not_resettable"}}},
          {%{method: "GET", path: "/api/sandboxes/#{disk}"}, response},
          {%{method: "DELETE", path: "/api/sandboxes/#{disk}"},
           {422, [], %{error: "sandbox_not_resettable"}}},
          {%{method: "GET", path: "/api/sandboxes/#{disk}"},
           {200, [], %{data: %{id: disk, status: "terminated"}}}},
          {%{method: "DELETE", path: "/api/vaults/copy"}, {204, [], ""}},
          {%{method: "GET", path: "/api/vaults/copy"}, {404, [], %{error: "not_found"}}}
        ])

      Sandbox.advance(client, op.id)
      assert Store.get_track(track.id).closed_at == nil
      pending = Store.get_operation(op.id)
      assert pending.completed_at == nil
      refute Enum.any?(FakeTransport.calls(client), &String.contains?(&1.path, "vaults"))
      {:ok, _} = Store.update_operation(pending, %{retry_at: nil})
      Sandbox.advance(client, op.id)
      assert Store.get_track(track.id).closed_at
      assert Store.get_operation(op.id).completed_at
    end
  end

  test "last shared close retains project secrets and gates a racing shared open until deletion" do
    stub(Ravix.Config, :retire_shared_machines?, fn -> true end)
    project = insert_project()
    first = insert_track(project: project)
    last = insert_track(project: project)
    insert_track(project: project, sandbox_layout: :dedicated, sandbox_id: "own")
    assert {:ok, :ok} = Store.close_shared(first, project)
    assert Store.operations(first.id) == []
    assert {:ok, :ok} = Store.close_shared(last, project)
    [op] = Store.operations(last.id)

    assert {:error, {:conflict, "machine_cleanup_pending", _}} =
             Store.shared_open(project.id, fn -> flunk("must not allocate") end)

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/sandboxes"},
         {200, [],
          %{
            data: [
              %{
                id: "shared",
                agent_id: project.agent_id,
                environment_id: project.environment_id,
                vault_id: project.vault_id
              },
              %{
                id: "own",
                agent_id: project.agent_id,
                environment_id: project.environment_id,
                vault_id: "dedicated"
              }
            ]
          }}},
        {%{method: "DELETE", path: "/api/sandboxes/shared"}, {204, [], ""}},
        {%{method: "GET", path: "/api/sandboxes/shared"},
         {200, [], %{data: %{id: "shared", status: "terminated"}}}}
      ])

    Sandbox.advance(client, op.id)
    assert Store.get_operation(op.id).completed_at
    assert Store.shared_open(project.id, fn -> :allowed end) == :allowed
    refute Enum.any?(FakeTransport.calls(client), &String.contains?(&1.path, "vaults"))
  end

  test "close after copy success before its database write discovers and removes the orphan" do
    {_project, track, op} = operation()
    {:ok, op} = Store.update_operation(op, %{phase: "copying"})
    assert {:ok, :ok} = Store.request_close(track)

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/vaults"},
         {200, [], %{data: [%{id: "orphan", name: "ravix-track-#{track.id}-1"}]}}},
        {%{method: "DELETE", path: "/api/vaults/orphan"}, {204, [], ""}},
        {%{method: "GET", path: "/api/vaults/orphan"}, {404, [], %{error: "not_found"}}}
      ])

    Sandbox.advance(client, op.id)
    assert Store.get_operation(op.id).completed_at
    assert Store.get_track(track.id).sandbox_state == :closing
    [_, close] = Store.operations(track.id)
    Sandbox.advance(client, close.id)
    assert Store.get_track(track.id).closed_at
  end

  test "clone access failure deletes the copied secrets and explicit retry reuses durable intent" do
    {project, track, op} = operation()
    Repo.update!(Ecto.Changeset.change(project, installation_id: 42))
    stub(Ravix.Config, :github, fn -> nil end)

    client =
      FakeTransport.client([
        {%{method: "POST", path: "/api/vaults/#{project.vault_id}/copy"},
         {201, [], %{data: %{id: "copy", name: "track"}}}},
        {%{method: "DELETE", path: "/api/vaults/copy"}, {204, [], ""}},
        {%{method: "GET", path: "/api/vaults/copy"}, {404, [], %{error: "not_found"}}}
      ])

    Sandbox.advance(client, op.id)
    failed = Store.get_track(track.id)
    assert failed.setup_error_code == "clone_auth_failed"
    assert failed.setup_error =~ "Repository access"
    assert {:ok, _} = Store.retry(failed)
    assert Store.get_operation(op.id).phase == "pending"
    refute Store.get_operation(op.id).resource_ids["vault_id"]
  end

  test "rebuild deletes both old resources and cleans the fresh copy on subsequent failure" do
    {project, track, op} = operation()

    {:ok, op} =
      Store.update_operation(op, %{
        phase: "done",
        completed_at: DateTime.utc_now(),
        resource_ids:
          Map.merge(op.resource_ids, %{"sandbox_id" => "old", "vault_id" => "old-copy"})
      })

    {:ok, track} =
      Store.update_sandbox(track.id, op.generation, %{
        sandbox_id: "old",
        vault_id: "old-copy",
        sandbox_state: :ready
      })

    sibling =
      insert_track(
        project: project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_id: "sibling-disk",
        vault_id: "sibling-copy"
      )

    assert {:ok, _} = Store.request_rebuild(track, project)
    [_, rebuild] = Store.operations(track.id)

    client =
      FakeTransport.client([
        {%{method: "DELETE", path: "/api/sandboxes/old"}, {204, [], ""}},
        {%{method: "GET", path: "/api/sandboxes/old"},
         {200, [], %{data: %{id: "old", status: "terminated"}}}},
        {%{method: "DELETE", path: "/api/vaults/old-copy"}, {204, [], ""}},
        {%{method: "GET", path: "/api/vaults/old-copy"}, {404, [], %{error: "not_found"}}},
        {%{method: "POST", path: "/api/vaults/#{project.vault_id}/copy"},
         {201, [], %{data: %{id: "new-copy", name: "new"}}}},
        {%{method: "POST", path: "/api/conversations"},
         {422, [], %{error: "sandbox_creation_failed"}}},
        {%{method: "DELETE", path: "/api/vaults/new-copy"}, {204, [], ""}},
        {%{method: "GET", path: "/api/vaults/new-copy"}, {404, [], %{error: "not_found"}}}
      ])

    Sandbox.advance(client, rebuild.id)
    assert %{phase: "failed"} = Store.get_operation(rebuild.id)
    assert %{sandbox_generation: 2, vault_id: nil, sandbox_id: nil} = Store.get_track(track.id)
    assert Store.get_track(sibling.id) == sibling
    assert Store.operations(sibling.id) == []
    refute Enum.any?(FakeTransport.calls(client), &String.contains?(&1.path, "sibling"))
  end

  test "cleanup remains pending until deletion is confirmed, then retries idempotently" do
    {_project, track, op} = operation()

    {:ok, op} =
      Store.update_operation(op, %{
        phase: "cleanup",
        resource_ids: %{"vault_id" => "copy"},
        error: %{code: "setup_failed"}
      })

    client =
      FakeTransport.client([
        {%{method: "DELETE", path: "/api/vaults/copy"}, {204, [], ""}},
        {%{method: "GET", path: "/api/vaults/copy"},
         {200, [], %{data: %{id: "copy", name: "pending deletion"}}}},
        {%{method: "DELETE", path: "/api/vaults/copy"}, {404, [], %{error: "not_found"}}},
        {%{method: "GET", path: "/api/vaults/copy"}, {404, [], %{error: "not_found"}}}
      ])

    Sandbox.advance(client, op.id)

    assert %{phase: "cleanup", completed_at: nil, cleanup: %{"pending" => true}} =
             pending = Store.get_operation(op.id)

    {:ok, _} = Store.update_operation(pending, %{retry_at: nil})
    Sandbox.advance(client, op.id)
    assert Store.get_operation(op.id).phase == "failed"
    assert Store.get_track(track.id).vault_id == nil
  end

  test "the supervised sweep recovers unwatched operations without a page" do
    {project, track, op} = operation()

    client =
      FakeTransport.client([
        {%{method: "POST", path: "/api/vaults/#{project.vault_id}/copy"},
         {422, [], %{error: "secret_not_copyable"}}}
      ])

    stub(Ravix.Fountain, :client, fn -> client end)
    pid = start_supervised!({Sandbox.Reconciler, interval: false})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    allow(Ravix.Fountain, self(), pid)
    send(pid, :tick)
    assert :sys.get_state(pid) == false
    assert Store.get_operation(op.id).phase == "failed"
    assert Store.get_track(track.id).setup_error_code == "secret_not_copyable"
  end

  test "close checks report dirty and unpushed state without exposing repository output" do
    project = insert_project()
    owner = Repo.get!(Ravix.Accounts.User, project.user_id)
    track = insert_track(project: project, sandbox_layout: :dedicated, sandbox_id: "disk")

    for {output, expected} <- [
          {" M private-file\nRAVIX_COMMITS\n2\n", %{dirty: true, unpushed: true}},
          {"RAVIX_COMMITS\n0\n", %{dirty: false, unpushed: false}},
          {"RAVIX_COMMITS\nunknown\n", %{dirty: false, unpushed: :unknown}}
        ] do
      expect(Ravix.Terminal, :exec, fn user, id, request ->
        assert user.id == owner.id and id == track.id
        assert request.command =~ "git status --porcelain"
        {:ok, %{stdout: output, code: 0}}
      end)

      assert {:ok, ^expected} = Ravix.Tracks.close_info(owner, track.id)
    end

    assert {:error, :not_found} = Ravix.Tracks.close_info(insert_user(), track.id)
  end

  test "a pending source write refuses overlap until its outcome is confirmed" do
    {project, _track, _op} = operation()
    assert {:ok, 1} = Ravix.Projects.Store.begin_secret_change(project.id)
    assert {:error, :secrets_pending} = Ravix.Projects.Store.begin_secret_change(project.id)
    assert :ok = Ravix.Projects.Store.finish_secret_change(project.id, 0)
    assert Ravix.Projects.Store.live_project(project.id).secrets_pending
    assert :ok = Ravix.Projects.Store.finish_secret_change(project.id, 1)
    assert {:ok, 2} = Ravix.Projects.Store.begin_secret_change(project.id)
  end

  test "shared allocation and last close cannot cross the retirement fence" do
    stub(Ravix.Config, :retire_shared_machines?, fn -> true end)
    project = insert_project()
    track = insert_track(project: project)
    parent = self()

    opening =
      Task.async(fn ->
        Store.shared_open(project.id, fn ->
          refute Repo.in_transaction?()
          send(parent, :allocating)

          receive do
            :finish -> insert_track(project: project)
          end
        end)
      end)

    assert_receive :allocating, 1_000

    assert {:error, {:conflict, "project_change_in_progress", _}} =
             Store.close_shared(track, project)

    assert Store.operations(track.id) == []
    refute Store.get_track(track.id).closed_at
    send(opening.pid, :finish)
    next = Task.await(opening)
    assert {:ok, :ok} = Store.close_shared(track, project)
    assert Store.operations(track.id) == []
    assert {:ok, :ok} = Store.close_shared(next, project)
    assert [%{action: :close}] = Store.operations(next.id)

    assert {:error, {:conflict, "machine_cleanup_pending", _}} =
             Store.shared_open(project.id, fn -> flunk("allocated across retirement") end)
  end

  test "retirement disabled does not acquire the shared mutation lock" do
    stub(Ravix.Config, :retire_shared_machines?, fn -> false end)
    project = insert_project()
    track = insert_track(project: project)
    parent = self()

    holder =
      Task.async(fn ->
        Ravix.Cluster.project_mutation(project.id, :shared_machine, fn ->
          send(parent, :locked)
          receive do: (:finish -> :ok)
        end)
      end)

    assert_receive :locked
    assert :allowed = Store.shared_open(project.id, fn -> :allowed end)
    assert {:ok, :ok} = Store.close_shared(track, project)
    assert Store.operations(track.id) == []
    send(holder.pid, :finish)
    Task.await(holder)
  end

  test "legacy retirement fails after bounded retries and releases its fence" do
    stub(Ravix.Config, :retire_shared_machines?, fn -> true end)

    project =
      Repo.update!(
        Ecto.Changeset.change(insert_project(), shared_home_runtime: "missing-runtime")
      )

    track = insert_track(project: project)
    assert {:ok, :ok} = Store.close_shared(track, project)
    assert {:ok, :ok} = Store.close_shared(track, project)
    [op] = Store.operations(track.id)
    client = FakeTransport.client([])

    for attempt <- 1..5 do
      Sandbox.advance(client, op.id)
      current = Store.get_operation(op.id)
      assert current.attempts == attempt
      if attempt < 5, do: Store.update_operation(current, %{retry_at: nil})
    end

    assert %{phase: "failed", completed_at: %DateTime{}} = Store.get_operation(op.id)
    refute Ravix.Projects.Store.live_project(project.id).shared_machine_retiring
    assert Store.shared_open(project.id, fn -> :allowed end) == :allowed
    assert FakeTransport.calls(client) == []
  end

  test "turning retirement off cancels pending legacy work without provider calls" do
    stub(Ravix.Config, :retire_shared_machines?, fn -> true end)
    project = insert_project()
    track = insert_track(project: project)
    {:ok, :ok} = Store.close_shared(track, project)
    [op] = Store.operations(track.id)
    stub(Ravix.Config, :retire_shared_machines?, fn -> false end)
    client = FakeTransport.client([])
    Sandbox.advance(client, op.id)
    assert %{phase: "failed"} = Store.get_operation(op.id)
    refute Ravix.Projects.Store.live_project(project.id).shared_machine_retiring
    assert FakeTransport.calls(client) == []
  end

  test "last shared cleanup follows its pinned home runtime and releases that pin" do
    stub(Ravix.Config, :retire_shared_machines?, fn -> true end)
    project = insert_project(runtime: "claude")
    :ok = Ravix.Projects.Store.reserve_runtime(project.id, "codex")
    :ok = Ravix.Projects.Store.bind_runtime(project.id, "codex", "codex-home", nil)
    project = Repo.update!(Ecto.Changeset.change(project, shared_home_runtime: "codex"))
    track = insert_track(project: project)
    assert {:ok, :ok} = Store.close_shared(track, project)
    [op] = Store.operations(track.id)
    assert op.resource_ids["agent_id"] == "codex-home"

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/sandboxes"},
         {200, [],
          %{
            data: [
              %{
                id: "disk",
                agent_id: "codex-home",
                environment_id: project.environment_id,
                vault_id: project.vault_id
              }
            ]
          }}},
        {%{method: "DELETE", path: "/api/sandboxes/disk"}, {204, [], ""}},
        {%{method: "GET", path: "/api/sandboxes/disk"},
         {200, [], %{data: %{id: "disk", status: "terminated"}}}}
      ])

    Sandbox.advance(client, op.id)
    assert Ravix.Projects.Store.live_project(project.id).shared_home_runtime == nil
  end

  test "a thread attach begun before rebuild cannot bind its old conversation afterward" do
    {_project, track, _op} = operation()

    attrs = %{
      id: Ecto.UUID.generate(),
      track_id: track.id,
      conversation_id: "late-attach",
      title: "Late thread"
    }

    assert {:error, :not_found} = Ravix.Tracks.Store.create_thread(attrs, 0)
    assert length(Ravix.Tracks.Store.threads_of(track.id)) == 1
    assert {:ok, _} = Ravix.Tracks.Store.create_thread(attrs, 1)
  end
end

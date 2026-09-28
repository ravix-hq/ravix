defmodule Ravix.TrackSandboxesTest do
  use Ravix.DataCase, async: true

  import Mimic

  setup :verify_on_exit!

  alias Ecto.Adapters.SQL
  alias Ravix.Accounts.Access
  alias Ravix.Fountain.{Client, FakeTransport}
  alias Ravix.MachineCache
  alias Ravix.Tracks
  alias Ravix.Tracks.Sandbox.{Operation, Store}
  alias Ravix.Tracks.{Thread, Track}

  test "old writer inserts omit ownership fields and retain the existing default thread" do
    project = insert_project()
    attrs = track_attrs(project: project, conversation_id: "legacy-conversation")

    fields =
      ~w(id project_id slug title branch workdir origin_kind created_by_login conversation_id)

    values = Enum.map(fields, &Map.fetch!(attrs, &1))
    placeholders = Enum.map_join(1..length(fields), ",", &"$#{&1}")

    SQL.query!(
      Repo,
      "INSERT INTO ravix.tracks (#{Enum.join(fields, ",")}, created_at) VALUES (#{placeholders}, NOW())",
      values
    )

    track = Repo.get!(Track, attrs["id"])
    assert track.sandbox_layout == :shared
    assert track.sandbox_generation == 0
    assert is_nil(track.sandbox_state)
    assert is_nil(track.sandbox_id)
    assert is_nil(track.vault_id)
    assert Repo.get!(Thread, track.id).conversation_id == "legacy-conversation"

    # A pre-expand UPDATE knows nothing about ownership and leaves it intact.
    SQL.query!(Repo, "UPDATE ravix.tracks SET title = $1 WHERE id = $2", [
      "old writer",
      track.id
    ])

    assert Repo.get!(Track, track.id).sandbox_layout == :shared
  end

  test "dedicated fields round trip and existing threads remain associated" do
    track =
      insert_track(
        sandbox_layout: :dedicated,
        sandbox_id: "dedicated",
        vault_id: "vault",
        sandbox_generation: 4,
        sandbox_state: :ready
      )

    loaded = Repo.get!(Track, track.id) |> Repo.preload(:threads)
    assert loaded.sandbox_layout == :dedicated
    assert loaded.sandbox_id == "dedicated"
    assert loaded.vault_id == "vault"
    assert loaded.sandbox_generation == 4
    assert loaded.sandbox_state == :ready
    assert [%Thread{track_id: id}] = loaded.threads
    assert id == track.id

    assert {:ok, %{track: ^track}} =
             Access.track_access(
               Repo.get!(
                 Ravix.Accounts.User,
                 Repo.get!(Ravix.Projects.Project, track.project_id).user_id
               ),
               track.id
             )
  end

  test "only non-null dedicated sandbox IDs are unique" do
    project = insert_project()
    insert_track(project: project, sandbox_layout: :shared, sandbox_id: "same")
    insert_track(project: project, sandbox_layout: :shared, sandbox_id: "same")
    insert_track(project: project, sandbox_layout: :dedicated, sandbox_id: "same")
    insert_track(project: project, sandbox_layout: :dedicated)
    insert_track(project: project, sandbox_layout: :dedicated)

    assert {:error, changeset} =
             %Track{}
             |> Track.changeset(
               track_attrs(project: project, sandbox_layout: :dedicated, sandbox_id: "same")
             )
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).sandbox_id
  end

  test "intent is atomic, retries preserve generation, and late results cannot replace ownership" do
    track = insert_track(sandbox_layout: :dedicated, sandbox_id: "old", vault_id: "old-vault")
    assert {:ok, operation} = Store.begin_operation(track.id, 0, :rebuild)
    assert operation.generation == 1
    assert operation.resource_ids == %{"sandbox_id" => "old", "vault_id" => "old-vault"}
    assert {:error, :stale_generation} = Store.begin_operation(track.id, 0, :open)
    assert [^operation] = Store.operations(track.id)

    assert {:ok, progress} =
             Store.update_operation(operation, %{
               attempts: 1,
               error: %{"code" => "timeout"},
               cleanup: %{"sandbox_id" => "old"}
             })

    assert progress.revision == 2
    assert {:error, stale} = Store.update_operation(operation, %{attempts: 2})
    assert "is stale" in errors_on(stale).revision
    assert [^progress] = Store.operations(track.id)

    assert {:ok, updated} =
             Store.update_sandbox(track.id, 1, %{
               sandbox_id: "new",
               vault_id: "new-vault",
               sandbox_state: :ready
             })

    assert updated.sandbox_generation == 1
    assert {:ok, close} = Store.begin_operation(track.id, 1, :close)
    assert close.generation == 2
    assert close.resource_ids["sandbox_id"] == "new"
    assert {:error, :stale_generation} = Store.update_sandbox(track.id, 1, %{sandbox_id: "late"})
    assert Repo.get!(Track, track.id).sandbox_id == "new"

    # Cleanup of historical generations survives a newer intent and reload.
    assert {:ok, completed} =
             Store.update_operation(progress, %{cleanup: %{}, completed_at: DateTime.utc_now()})

    assert [^completed, ^close] = Store.operations(track.id)
    assert {:ok, open} = Store.begin_operation(track.id, 2, :open)
    assert open.action == :open
    assert Repo.get!(Track, track.id).sandbox_state == :provisioning
  end

  test "each intent names its action so a rebuild reads Restarting, and a new intent wakes the row" do
    track =
      insert_track(
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_suspended_at: DateTime.utc_now()
      )

    assert {:ok, _} = Store.begin_operation(track.id, 0, :rebuild)
    row = Repo.get!(Track, track.id)
    assert {row.sandbox_state, row.sandbox_action} == {:provisioning, :rebuild}
    assert is_nil(row.sandbox_suspended_at)

    assert {:ok, _} = Store.update_sandbox(track.id, 1, %{sandbox_state: :ready})
    assert {:ok, _} = Store.begin_operation(track.id, 1, :close)
    assert Repo.get!(Track, track.id).sandbox_action == :close
    assert {:ok, _} = Store.begin_operation(track.id, 2, :open)
    row = Repo.get!(Track, track.id)
    assert {row.sandbox_state, row.sandbox_action} == {:provisioning, :open}
  end

  test "a row the previous release wrote mid-open reads as Starting, never Restarting" do
    project = insert_project()
    attrs = track_attrs(project: project)

    fields = ~w(id project_id slug title branch workdir origin_kind created_by_login)
    values = Enum.map(fields, &Map.fetch!(attrs, &1))
    placeholders = Enum.map_join(1..length(fields), ",", &"$#{&1}")

    # The old writer knows neither new column; its open and its rebuild both
    # wrote `provisioning` and nothing else.
    SQL.query!(
      Repo,
      "INSERT INTO ravix.tracks (#{Enum.join(fields, ",")}, sandbox_layout, sandbox_state, " <>
        "sandbox_stage, setup_state, created_at) " <>
        "VALUES (#{placeholders}, 'dedicated', 'provisioning', 'creating', 'pending', NOW())",
      values
    )

    row = Repo.get!(Track, attrs["id"])
    assert is_nil(row.sandbox_action)
    assert is_nil(row.sandbox_suspended_at)

    assert %{state: :starting, detail: "Creating this track's machine…"} =
             row |> Tracks.present() |> Tracks.MachineState.of()
  end

  test "invalid and stale mutations preserve records; shared rows cannot acquire dedicated intent" do
    shared = insert_track()
    assert {:error, :stale_generation} = Store.begin_operation(shared.id, 0, :open)
    assert {:error, :stale_generation} = Store.update_sandbox("missing", 0, %{})
    assert Store.operations(shared.id) == []
    track = insert_track(sandbox_layout: :dedicated)
    assert {:error, changeset} = Store.update_sandbox(track.id, 0, %{sandbox_state: :unknown})
    assert errors_on(changeset).sandbox_state
    assert is_nil(Repo.get!(Track, track.id).sandbox_state)
    assert {:ok, operation} = Store.begin_operation(track.id, 0, :open)
    assert {:error, changeset} = Store.update_operation(operation, %{attempts: -1})
    assert errors_on(changeset).attempts

    assert {:error, changeset} =
             %Operation{}
             |> Operation.changeset(%{track_id: track.id, generation: 1, action: :open})
             |> Repo.insert()

    assert errors_on(changeset).track_id
  end

  test "an operation conflict rolls back the generation and state transition" do
    track = insert_track(sandbox_layout: :dedicated)

    %Operation{}
    |> Operation.changeset(%{track_id: track.id, generation: 1, action: :open})
    |> Repo.insert!()

    assert {:error, changeset} = Store.begin_operation(track.id, 0, :open)
    assert errors_on(changeset).track_id
    assert Repo.get!(Track, track.id).sandbox_generation == 0
    assert is_nil(Repo.get!(Track, track.id).sandbox_state)
  end

  test "shared rows retain project discovery even with an unresolved stored legacy ID" do
    project = insert_project()
    track = insert_track(project: project, sandbox_id: "unverified-legacy")

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
         {200, [], %{data: [%{"id" => "live", "sandbox_id" => "discovered", "status" => "idle"}]}}}
      ])

    assert {:ok, %{sandbox_id: "discovered"}} =
             MachineCache.machine_for_track(client, project, track)

    assert length(FakeTransport.calls(client)) == 1
  end

  test "dedicated reads use ownership even without live threads and unresolved IDs never fall back" do
    client = FakeTransport.client([])
    stub(Ravix.Fountain, :client, fn -> client end)
    project = insert_project()
    user = Repo.get!(Ravix.Accounts.User, project.user_id)
    member = insert_user()
    stranger = insert_user()
    track = insert_track(project: project, sandbox_layout: :dedicated, sandbox_id: "owned")
    insert_track_member(track, member)
    assert {:ok, %{sandbox_id: "owned"}} = Tracks.machine_for_track(user, track.id)
    assert {:ok, %{sandbox_id: "owned"}} = Tracks.machine_for_track(member, track.id)
    assert {:error, :not_found} = Tracks.machine_for_track(stranger, track.id)
    sibling = insert_track(project: project, sandbox_layout: :dedicated, sandbox_id: "sibling")
    assert {:error, :not_found} = Tracks.machine_for_track(member, sibling.id)

    assert {:ok, nil} =
             MachineCache.machine_for_track(%Client{}, project, %{track | sandbox_id: nil})

    assert {:ok, nil} =
             MachineCache.machine_for_track(%Client{}, project, %{track | sandbox_id: ""})

    Repo.delete_all(Ravix.Tracks.TrackMember)
    assert {:error, :not_found} = Tracks.machine_for_track(member, track.id)
  end
end

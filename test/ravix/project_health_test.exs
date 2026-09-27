defmodule Ravix.ProjectHealthTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.{Accounts, Projects}
  alias Ravix.Accounts.Inference

  test "funding is scoped to the project owner for owners, project members and track guests" do
    owner = insert_user(credential_set_id: "owner-set")
    member = insert_user(credential_set_id: "member-set")
    guest = insert_user()
    stranger = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    track = insert_track(project: project)
    insert_project_member(project, member)
    insert_track_member(track, guest)

    expect(Inference, :usable?, 3, fn caller, "codex", [] ->
      assert caller.id == owner.id
      assert caller.credential_set_id == "owner-set"
      {:ok, false}
    end)

    for viewer <- [owner, member, guest] do
      assert {:ok, health} = Projects.agent_health(viewer, project.id)
      assert health.owner_login == owner.login
      assert health.owner? == (viewer.id == owner.id)
      assert health.usable? == false
      assert Projects.visible?(viewer, project.id)
    end

    assert {:error, :not_found} = Projects.agent_health(stranger, project.id)
    refute Projects.visible?(stranger, project.id)
    assert {:error, :not_found} = Projects.agent_health(owner, Ecto.UUID.generate())
  end

  test "unknown availability stays unknown and a stale owner struct is reloaded" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    {:ok, _} = Accounts.save_setup(owner, %{credential_set_id: "new-set"})

    expect(Inference, :usable?, fn caller, "codex", [] ->
      assert caller.credential_set_id == "new-set"
      {:error, :offline}
    end)

    assert {:ok, %{usable?: nil}} = Projects.agent_health(owner, project.id)
  end

  test "only a held Codex subscription exposes a reset time, without account details" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    stub(Inference, :usable?, fn _, _, _ -> {:ok, true} end)
    stub(Inference, :held, fn _ -> {:ok, [{:codex, :subscription}]} end)

    expect(Inference, :subscription, fn caller ->
      assert caller.id == owner.id

      {:ok,
       %{
         status: "active",
         exhausted_until: "2026-10-01T09:00:00Z",
         account_email: "private@example.com"
       }}
    end)

    assert {:ok, health} = Projects.agent_health(owner, project.id)
    assert health.exhausted_until == "2026-10-01T09:00:00Z"
    refute Map.has_key?(health, :account_email)

    stub(Inference, :held, fn _ -> {:ok, [{:codex, :api_key}]} end)
    reject(&Inference.subscription/1)
    assert {:ok, %{exhausted_until: nil}} = Projects.agent_health(owner, project.id)
  end

  test "unavailable ChatGPT status does not produce a reset warning" do
    owner = insert_user()
    project = insert_project(user: owner, runtime: "codex")
    stub(Inference, :usable?, fn _, _, _ -> {:ok, true} end)
    stub(Inference, :held, fn _ -> {:ok, [{:codex, :subscription}]} end)

    for response <- [
          {:error, :offline},
          {:ok, nil},
          {:ok, %{status: "disconnected", exhausted_until: "old"}}
        ] do
      expect(Inference, :subscription, fn _ -> response end)
      assert {:ok, %{exhausted_until: nil}} = Projects.agent_health(owner, project.id)
    end
  end

  test "disconnect impact excludes shared, foreign, archived and other-runtime projects" do
    owner = insert_user()
    own = insert_project(user: owner, runtime: "codex")
    insert_project(user: owner, runtime: "claude")
    insert_project(user: owner, runtime: "codex", archived_at: DateTime.utc_now())
    foreign = insert_project(runtime: "codex")
    insert_project_member(foreign, owner)
    assert [project] = Projects.projects_using_agent(owner, :codex)
    assert project.id == own.id
  end
end

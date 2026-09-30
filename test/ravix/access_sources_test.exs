defmodule Ravix.AccessSourcesTest do
  @moduledoc """
  RAV-75: where each person's access to a project or a track comes from --
  the owner, a direct grant, the project, or the workspace -- and the
  precedence between them: owner, then direct, then project, then
  workspace. The nearest grant decides, whether it is higher or lower than
  the next, so a direct Read on a workspace member really is Read at every
  door, and removing it falls back to the workspace's Write.

  The fixture is the one the issue describes: a workspace of four, a
  project in it with two direct grants, and a fourth member nobody named.
  The switch is stubbed per process, so this file stays async; `Access`
  itself is never stubbed.
  """
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.Access
  alias Ravix.Fountain.Client
  alias Ravix.{People, Previews, PromptQueue, Terminal, Tooling, Tracks, Workspaces}
  alias Ravix.People.Store, as: PeopleStore
  alias Ravix.Projects.Project
  alias Ravix.ToolingFixture
  alias Ravix.Workspaces.{Membership, Store}

  setup do
    stub(Ravix.Config, :workspace_access?, fn -> true end)
    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    stub(Ravix.MachineCache, :environment, fn _, _ -> {:error, :offline} end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

    [owner, alice, bob, carol] =
      for name <- ~w(owner alice bob carol),
          do: insert_user(login: "#{name}#{System.unique_integer([:positive])}")

    {:ok, workspace} = Store.create_team_workspace(owner.id, "Ravi")
    for user <- [alice, bob, carol], do: member!(workspace, user)

    project = in_workspace(insert_project(user: owner, name: "Ravi app"), workspace)
    insert_project_member(project, alice, role: :write)
    insert_project_member(project, bob, role: :write)

    track =
      insert_track(
        project: project,
        conversation_id: "c1",
        created_by: owner.id,
        created_by_login: owner.login
      )

    %{
      owner: owner,
      alice: alice,
      bob: bob,
      carol: carol,
      workspace: workspace,
      project: project,
      track: track
    }
  end

  defp member!(workspace, user) do
    %Membership{}
    |> Membership.changeset(%{workspace_id: workspace.id, user_id: user.id, role: :member})
    |> Repo.insert!()
  end

  defp in_workspace(project, workspace) do
    Repo.update_all(where(Project, id: ^project.id), set: [workspace_id: workspace.id])
    Repo.get!(Project, project.id)
  end

  defp reach(people),
    do: Enum.map(people, fn {user, level, source} -> {user.id, level, source} end)

  defp prompt(user, track),
    do: Tracks.prompt(user, track.id, %{prompt: "go", request_id: Ecto.UUID.generate()})

  describe "project_people/2" do
    test "lists everyone who reaches the project, the unnamed member as from workspace", c do
      assert {:ok, people} = Access.project_people(c.owner, c.project.id)

      assert reach(people) == [
               {c.owner.id, :admin, :owner},
               {c.alice.id, :write, :direct},
               {c.bob.id, :write, :direct},
               {c.carol.id, :write, :workspace}
             ]

      # The door agrees with the list: the member nobody named reaches the
      # project, at Write.
      assert {:ok, %{level: :write}} = Access.project_access(c.carol, c.project.id)
      assert {:ok, %{level: :write}} = Access.track_access(c.carol, c.track.id)
      # Anybody in the project may read it.
      assert {:ok, ^people} = Access.project_people(c.carol, c.project.id)
    end

    test "the owner is always Admin · owner, and their role cannot be given", c do
      insert_project_member(c.project, c.owner, role: :read)
      assert {:ok, [{owner, :admin, :owner} | _]} = Access.project_people(c.alice, c.project.id)
      assert owner.id == c.owner.id
      assert {:ok, %{level: :admin}} = Access.project_access(c.owner, c.project.id)

      assert {:error, {:unprocessable, "owner", _}} =
               People.set_project_role(c.alice |> admin!(c), c.project.id, c.owner.login, "read")
    end

    test "another user's project id and a stranger see nothing", c do
      stranger = insert_user()
      assert {:error, :not_found} = Access.project_people(stranger, c.project.id)
      assert {:error, :not_found} = Access.track_people(stranger, c.track.id)
      assert {:error, :not_found} = People.list_project(stranger, c.project.id)
      assert {:error, :not_found} = People.workspace_base(stranger, c.project.id)

      assert {:error, :not_found} =
               People.set_project_role(stranger, c.project.id, c.carol.login, "admin")

      refute PeopleStore.project_member?(c.project.id, c.carol.id)
    end

    test "somebody the workspace removed sees nothing, and their direct grant goes with them",
         c do
      assert {:ok, _} = People.set_project_role(c.owner, c.project.id, c.carol.login, "read")
      assert :ok = Workspaces.remove_member(c.owner, c.workspace.id, c.carol.id)

      refute PeopleStore.project_member?(c.project.id, c.carol.id)
      assert {:error, :not_found} = Access.project_people(c.carol, c.project.id)
      assert {:error, :not_found} = Access.project_access(c.carol, c.project.id)
      assert {:error, :not_found} = Access.track_access(c.carol, c.track.id)
      assert {:ok, people} = Access.project_people(c.owner, c.project.id)
      refute Enum.any?(people, fn {user, _, _} -> user.id == c.carol.id end)
    end

    test "with the switch off a workspace grants nothing and lists nobody from it", c do
      stub(Ravix.Config, :workspace_access?, fn -> false end)
      assert {:ok, people} = Access.project_people(c.owner, c.project.id)
      refute Enum.any?(people, fn {_, _, source} -> source == :workspace end)
      assert {:error, :not_found} = Access.project_people(c.carol, c.project.id)
      assert {:ok, nil} = People.workspace_base(c.owner, c.project.id)
    end
  end

  describe "a direct grant overrides the workspace" do
    test "upward: Admin, which may manage the project's people but not its settings", c do
      insert_track_member(c.track, c.bob, role: :write)
      insert_track_member(c.track, c.carol, role: :read)
      Ravix.Hub.subscribe(c.project.id)

      assert {:ok, people} =
               People.set_project_role(c.owner, c.project.id, c.carol.login, "admin")

      assert_receive {:hub, %Ravix.Hub.Event{name: :people}}

      carol = Enum.find(people, &(&1.login == c.carol.login))
      assert %{role: :admin, source: :direct, via: :project, fallback: :write} = carol

      assert {:ok, %{level: :admin}} = Access.project_access(c.carol, c.project.id)
      # Admin is not the machine (ADR 0010): settings stay the owner's.
      assert {:error, :not_found} = Access.project_of(c.carol, c.project.id)
      # Unlike an invitation to the project, the grant leaves track seats
      # alone (ADR 0009); the seat is nearer, so it still decides there.
      assert PeopleStore.project_member?(c.project.id, c.carol.id)
      assert PeopleStore.member_role(c.track.id, c.carol.id) == :read
      assert {:ok, %{level: :read}} = Access.track_access(c.carol, c.track.id)
    end

    test "downward: Read, refused at every door that writes", c do
      assert {:ok, _} = People.set_project_role(c.owner, c.project.id, c.carol.login, "read")
      assert {:ok, people} = Access.project_people(c.owner, c.project.id)
      assert {c.carol.id, :read, :direct} in reach(people)

      assert {:ok, %{level: :read}} = Access.project_access(c.carol, c.project.id)
      assert {:ok, %{level: :read}} = Access.track_access(c.carol, c.track.id)
      assert {:ok, track_people} = Access.track_people(c.owner, c.track.id)
      assert {c.carol.id, :read, :project} in reach(track_people)

      # A prompt, through the page and through MCP, and nothing is queued.
      assert {:error, {:forbidden, "Your role on this track is Read." <> _}} =
               prompt(c.carol, c.track)

      {principal, _, _} = ToolingFixture.principal(c.carol)

      assert {:error, {:forbidden, _}} =
               Tooling.call(principal, "send_prompt", %{
                 "track_id" => c.track.id,
                 "prompt" => "go",
                 "request_id" => "mcp-rav-75"
               })

      assert PromptQueue.Store.queued_prompts() == []

      # A command, and the interactive terminal.
      assert {:error, {:forbidden, _}} = Terminal.exec(c.carol, c.track.id, %{command: "pwd"})
      assert {:error, :not_found} = Terminal.open_tab(c.carol, c.track.id)

      # A commit and a push.
      assert {:error, {:forbidden, _}} = Tracks.commit_and_push(c.carol, c.track.id, "wip")
      assert {:error, {:forbidden, _}} = Tracks.push(c.carol, c.track.id)

      # The preview, and cutting a track on the project.
      assert {:error, {:forbidden, _}} = Previews.stop(c.carol, c.track.id)
      assert {:error, {:forbidden, _}} = Previews.save_config(c.carol, c.track.id, nil)

      assert {:error, {:forbidden, "Your role on this project is Read." <> _}} =
               Tracks.open(c.carol, c.project.id, %{"title" => "Nope"})

      # The same member without the grant writes.
      assert {:ok, _} = prompt(c.bob, c.track)
    end

    test "removing it falls back to the workspace's level, and nothing else goes", c do
      mine =
        insert_track(
          project: c.project,
          visibility: :private,
          sandbox_layout: :dedicated,
          created_by: c.carol.id,
          created_by_login: c.carol.login
        )

      assert {:ok, _} = People.set_project_role(c.owner, c.project.id, c.carol.login, "read")
      assert {:error, {:forbidden, _}} = prompt(c.carol, c.track)

      assert {:ok, people} = People.remove_project(c.owner, c.project.id, c.carol.login)
      assert %{role: :write, source: :workspace} = Enum.find(people, &(&1.login == c.carol.login))

      refute PeopleStore.project_member?(c.project.id, c.carol.id)
      assert {:ok, %{level: :write}} = Access.project_access(c.carol, c.project.id)
      assert {:ok, %{level: :write}} = Access.track_access(c.carol, c.track.id)
      assert {:ok, _} = prompt(c.carol, c.track)
      # Still their private track's creator: this was not a removal.
      assert {:ok, %{level: :admin}} = Access.track_access(c.carol, mine.id)
    end

    test "a member at the workspace's default leaving the project keeps it", c do
      assert {:ok, _} = People.remove_project(c.carol, c.project.id, c.carol.login)
      assert {:ok, %{level: :write}} = Access.project_access(c.carol, c.project.id)
    end

    test "only an admin gives a role, never their own, and never to an outsider", c do
      assert {:error, {:forbidden, _}} =
               People.set_project_role(c.alice, c.project.id, c.carol.login, "admin")

      outsider = insert_user()

      assert {:error, :not_found} =
               People.set_project_role(c.owner, c.project.id, outsider.login, "read")

      refute PeopleStore.project_member?(c.project.id, outsider.id)

      assert {:ok, _} = People.set_project_role(c.owner, c.project.id, c.carol.login, "admin")

      assert {:error, {:unprocessable, "own_role", _}} =
               People.set_project_role(c.carol, c.project.id, c.carol.login, "read")
    end

    test "a direct project grant on a track decides over the workspace, a seat over both", c do
      insert_track_member(c.track, c.alice, role: :read)
      insert_project_member(c.project, c.carol, role: :admin)

      assert {:ok, people} = Access.track_people(c.owner, c.track.id)

      assert [
               {c.owner.id, :admin, :owner},
               {c.alice.id, :read, :direct},
               {c.bob.id, :write, :project},
               {c.carol.id, :admin, :project}
             ] == reach(people)

      # The track list is the door's answer for each of them.
      for {id, level, _source} <- reach(people) do
        user = Enum.find([c.owner, c.alice, c.bob, c.carol], &(&1.id == id))
        assert {:ok, %{level: ^level}} = Access.track_access(user, c.track.id)
      end
    end
  end

  describe "the Share dialog's sources" do
    test "a workspace track lists owner, direct, project and workspace sources", c do
      insert_track_member(c.track, c.alice, role: :read)
      assert {:ok, sharing} = People.sharing(c.owner, c.track.id)

      sources =
        Map.new(sharing.access, fn {person, level, source} -> {person.login, {level, source}} end)

      assert sources == %{
               c.owner.login => {:admin, :owner},
               c.alice.login => {:read, :direct},
               c.bob.login => {:write, :project},
               c.carol.login => {:write, :workspace}
             }
    end

    test "a private track lists its creator and the people it is shared with", c do
      secret =
        insert_track(
          project: c.project,
          visibility: :private,
          sandbox_layout: :dedicated,
          created_by: c.alice.id,
          created_by_login: c.alice.login
        )

      assert :ok = People.share(c.alice, secret.id, c.carol.id)
      assert {:ok, sharing} = People.sharing(c.alice, secret.id)

      assert Enum.map(sharing.access, fn {p, level, source} -> {p.login, level, source} end) == [
               {c.alice.login, :admin, :owner},
               {c.carol.login, :write, :direct}
             ]

      # The project's owner and members are not on it: private is private.
      assert {:error, :not_found} = Access.track_people(c.owner, secret.id)
      assert {:error, :not_found} = Access.track_people(c.bob, secret.id)
    end

    test "a closed track lists only its owner", c do
      Repo.update_all(where(Ravix.Tracks.Track, id: ^c.track.id),
        set: [closed_at: DateTime.utc_now()]
      )

      assert {:ok, [{owner, :admin, :owner}]} = Access.track_people(c.owner, c.track.id)
      assert owner.id == c.owner.id
    end
  end

  # An admin of the project other than its owner, for the owner-role refusal.
  defp admin!(user, c) do
    PeopleStore.set_project_member_role(c.project.id, user.id, :admin)
    user
  end
end

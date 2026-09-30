defmodule Ravix.MemberRolesTest do
  @moduledoc """
  ADR 0010: Read, Write and Admin on track seats and project memberships.

  What a role decides is enforced at the context door, so these ask the
  contexts directly -- the same calls a LiveView event, an async result, an
  MCP tool and the prompt queue make -- and check both halves: somebody with
  the role gets through, and somebody without it is refused rather than told
  the track is not there.
  """
  use Ravix.DataCase, async: true
  import Mimic

  alias Ravix.Accounts.Access
  alias Ravix.Fountain.Client
  alias Ravix.Hub.Event
  alias Ravix.{People, PromptQueue, Schedules, Terminal, Tooling, Tracks}
  alias Ravix.People.Store, as: PeopleStore
  alias Ravix.ToolingFixture

  setup do
    owner = insert_user(login: "owner")
    reader = insert_user(login: "reader")
    writer = insert_user(login: "writer")
    admin = insert_user(login: "admin")
    project = insert_project(user: owner, repo_full_name: nil, installation_id: nil)

    track =
      insert_track(project: project, conversation_id: "c1", created_by_login: owner.login)

    insert_track_member(track, reader, role: :read)
    insert_track_member(track, writer, role: :write)
    insert_track_member(track, admin, role: :admin)

    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    stub(Ravix.MachineCache, :environment, fn _, _ -> {:error, :offline} end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

    %{owner: owner, reader: reader, writer: writer, admin: admin, project: project, track: track}
  end

  defp prompt(user, track),
    do: Tracks.prompt(user, track.id, %{prompt: "go", request_id: Ecto.UUID.generate()})

  describe "Access" do
    test "a seat's role is the level on its track, and the owner is admin", c do
      for {user, level} <- [
            {c.owner, :admin},
            {c.reader, :read},
            {c.writer, :write},
            {c.admin, :admin}
          ] do
        assert {:ok, %{level: ^level}} = Access.track_access(user, c.track.id)
        assert {:ok, %{level: ^level}} = Access.thread_access(user, c.track.id)
      end
    end

    test "a row from before roles, or from the previous release, reads as write", c do
      legacy = insert_user()
      insert_track_member(c.track, legacy)
      assert PeopleStore.member_role(c.track.id, legacy.id) == :write
      assert {:ok, %{level: :write}} = Access.track_access(legacy, c.track.id)
      assert PeopleStore.member_role(c.track.id, insert_user().id) == nil
    end

    test "track_access/3 refuses somebody who can see the track but lacks the role", c do
      assert {:ok, _} = Access.track_access(c.reader, c.track.id, :read)

      assert {:error,
              {:forbidden, "Your role on this track is Read. Ask an admin for Write" <> _}} =
               Access.track_access(c.reader, c.track.id, :write)

      assert {:error, {:forbidden, _}} = Access.track_access(c.writer, c.track.id, :admin)
      assert {:ok, _} = Access.track_access(c.admin, c.track.id, :admin)
      # A stranger still learns nothing.
      assert {:error, :not_found} = Access.track_access(insert_user(), c.track.id, :read)
    end

    test "a project role reaches project-visible tracks, never a private one", c do
      member = insert_user()
      insert_project_member(c.project, member, role: :read)
      assert {:ok, %{level: :read}} = Access.project_access(member, c.project.id)
      assert {:ok, %{level: :read}} = Access.track_access(member, c.track.id)

      assert {:error, {:forbidden, "Your role on this project is Read." <> _}} =
               Access.project_access(member, c.project.id, :write)

      private =
        insert_track(
          project: c.project,
          visibility: :private,
          sandbox_layout: :dedicated,
          created_by: c.writer.id
        )

      insert_project_member(c.project, c.writer, role: :read)
      # Its creator runs it, whatever their project role.
      assert {:ok, %{level: :admin}} = Access.track_access(c.writer, private.id)
      # A seat on it is that track's alone; the project admin role adds nothing.
      insert_project_member(c.project, c.admin, role: :admin)
      insert_track_member(private, c.admin, role: :read)
      assert {:ok, %{level: :read}} = Access.track_access(c.admin, private.id)
      # A track share never widens to the project.
      assert {:ok, %{level: :admin}} = Access.project_access(c.admin, c.project.id)
      assert {:error, :not_found} = Access.project_access(c.reader, c.project.id)
    end

    test "the highest grant wins on a project-visible track", c do
      insert_project_member(c.project, c.reader, role: :write)
      assert {:ok, %{level: :write}} = Access.track_access(c.reader, c.track.id)
    end

    test "the owner holds only their seat on somebody else's private track", c do
      private =
        insert_track(
          project: c.project,
          visibility: :private,
          sandbox_layout: :dedicated,
          created_by: c.writer.id
        )

      insert_track_member(private, c.owner, role: :read)
      assert {:ok, %{role: :owner, level: :read}} = Access.track_access(c.owner, private.id)
    end

    test "allows?/2 orders the roles and refuses anything else" do
      assert Access.allows?(:admin, :write)
      assert Access.allows?(:write, :read)
      refute Access.allows?(:read, :write)
      refute Access.allows?(nil, :read)
      refute Access.allows?(:owner, :read)
    end
  end

  describe "a read-only member" do
    test "cannot send a prompt, and nothing is queued", c do
      assert {:error, {:forbidden, _}} = prompt(c.reader, c.track)
      assert PromptQueue.Store.queued_prompts() == []
      assert {:ok, _} = prompt(c.writer, c.track)
    end

    test "cannot stop a turn, retry, start a thread or change the model", c do
      assert {:error, {:forbidden, _}} = Tracks.interrupt(c.reader, c.track.id)
      assert {:error, {:forbidden, _}} = Tracks.retry(c.reader, c.track.id)
      assert {:error, {:forbidden, _}} = Tracks.set_model(c.reader, c.track.id, nil, nil)

      assert {:error, {:forbidden, _}} =
               Tracks.start_thread(c.reader, c.track.id, %{}, %{prompt: "x"})
    end

    test "cannot run a command on the machine", c do
      assert {:error, {:forbidden, _}} = Terminal.exec(c.reader, c.track.id, %{command: "pwd"})
    end

    test "cannot open or attach an interactive terminal, but can list and close their own", c do
      assert {:error, :not_found} = Terminal.open_tab(c.reader, c.track.id)
      assert {:error, :not_found} = Terminal.attach(c.reader, "session", c.track.id, "tab")
      assert {:ok, []} = Terminal.tabs(c.reader, c.track.id)
      assert {:error, :not_found} = Terminal.close_tab(c.reader, c.track.id, Ecto.UUID.generate())

      # The same doors let a writer through: whatever comes back, it is not
      # the refusal a reader gets.
      refute Terminal.open_tab(c.writer, c.track.id) == {:error, :not_found}
    end

    test "cannot commit or push from Checks", c do
      assert {:error, {:forbidden, _}} = Tracks.commit_and_push(c.reader, c.track.id, "wip")
      assert {:error, {:forbidden, _}} = Tracks.push(c.reader, c.track.id)
    end

    test "cannot change the track's settings or open a pull request", c do
      mine =
        insert_track(project: c.project, created_by: c.reader.id, created_by_login: "reader")

      insert_project_member(c.project, c.reader, role: :read)
      assert {:error, {:forbidden, _}} = Tracks.rename(c.reader, mine.id, "Renamed")
      assert {:error, {:forbidden, _}} = Tracks.close(c.reader, mine.id)
      assert {:error, {:forbidden, _}} = Tracks.set_visibility(c.reader, mine.id, "project")
      stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)
      assert {:error, {:forbidden, _}} = Tracks.open_pull(c.reader, c.track.id, %{})
    end

    test "cannot cut a track or schedule prompts on a project it reads", c do
      insert_project_member(c.project, c.reader, role: :read)

      assert {:error, {:forbidden, _}} =
               Tracks.open(c.reader, c.project.id, %{"title" => "Nope"})

      assert {:error, {:forbidden, _}} =
               Schedules.create(c.reader, c.project.id, %{
                 "prompt" => "x",
                 "cadence" => "daily"
               })
    end

    test "cannot manage people, and anybody may still leave", c do
      assert {:error, {:forbidden, _}} = People.add(c.reader, c.track.id, "writer")
      assert {:error, {:forbidden, _}} = People.remove(c.reader, c.track.id, "writer")
      assert {:error, {:forbidden, _}} = People.set_role(c.reader, c.track.id, "writer", "read")
      assert {:error, {:forbidden, _}} = People.mint_link(c.reader, c.track.id)
      assert {:ok, :left} = People.remove(c.reader, c.track.id, "reader")
    end

    test "cannot send a prompt through MCP", c do
      {p, _, _} = ToolingFixture.principal(c.reader)

      assert {:error, {:forbidden, _}} =
               Tooling.call(p, "send_prompt", %{
                 "track_id" => c.track.id,
                 "prompt" => "go",
                 "request_id" => "mcp-read"
               })

      assert PromptQueue.Store.queued_prompts() == []

      assert {:error, {:forbidden, _}} =
               Tooling.call(p, "retry_setup", %{"track_id" => c.track.id})
    end

    test "can still read the track and copy its link", c do
      assert {:ok, _people} = People.list(c.reader, c.track.id)
      assert {:ok, url} = People.track_url(c.reader, c.track.id)
      assert url =~ "/p/#{c.project.id}/t/#{c.track.id}"
      assert {:error, :not_found} = People.track_url(insert_user(), c.track.id)
    end
  end

  describe "set_role/4" do
    test "an admin changes a seat's role, and the project's pages hear it", c do
      Ravix.Hub.subscribe(c.project.id)
      track_id = c.track.id

      assert {:ok, people} = People.set_role(c.admin, c.track.id, "@Writer", "read")
      assert Enum.find(people, &(&1.login == "writer")).role == :read
      assert {:ok, %{level: :read}} = Access.track_access(c.writer, c.track.id)
      assert_receive {:hub, %Event{name: :people, track_id: ^track_id}}
      assert {:error, {:forbidden, _}} = prompt(c.writer, c.track)

      assert {:ok, _} = People.set_role(c.owner, c.track.id, "writer", "admin")
      assert {:ok, %{level: :admin}} = Access.track_access(c.writer, c.track.id)
    end

    test "nobody changes their own role, the owner's, or somebody with no seat", c do
      assert {:error, {:unprocessable, "own_role", _}} =
               People.set_role(c.admin, c.track.id, "admin", "read")

      assert {:error, {:unprocessable, "owner", _}} =
               People.set_role(c.admin, c.track.id, "owner", "read")

      assert {:error, {:unprocessable, "invalid_role", _}} =
               People.set_role(c.admin, c.track.id, "writer", "owner")

      assert {:error, :not_found} = People.set_role(c.admin, c.track.id, "nobody-here", "read")

      wide = insert_user(login: "wide")
      insert_project_member(c.project, wide)

      assert {:error, {:conflict, "in_whole_project", _}} =
               People.set_role(c.admin, c.track.id, "wide", "read")

      assert {:error, :not_found} = People.set_role(insert_user(), c.track.id, "writer", "read")
    end

    test "a private track's creator is always its admin", c do
      private =
        insert_track(
          project: c.project,
          visibility: :private,
          sandbox_layout: :dedicated,
          created_by: c.writer.id
        )

      insert_project_member(c.project, c.writer)
      insert_track_member(private, c.admin, role: :admin)

      assert {:error, {:unprocessable, "creator", _}} =
               People.set_role(c.admin, private.id, "writer", "read")
    end

    test "an admin may invite and remove on the track they administer", c do
      guest = insert_user(login: "guest")
      assert {:ok, _} = People.add(c.admin, c.track.id, "guest")
      assert PeopleStore.member?(c.track.id, guest.id)
      assert {:ok, _} = People.remove(c.admin, c.track.id, "guest")
      refute PeopleStore.member?(c.track.id, guest.id)
    end
  end

  describe "set_project_role/4" do
    test "a project admin changes a member's role across the project", c do
      manager = insert_user(login: "manager")
      member = insert_user(login: "member")
      insert_project_member(c.project, manager, role: :admin)
      insert_project_member(c.project, member)
      Ravix.Hub.subscribe(c.project.id)

      assert {:ok, people} = People.set_project_role(manager, c.project.id, "member", "read")
      assert Enum.find(people, &(&1.login == "member")).role == :read
      assert_receive {:hub, %Event{name: :people, track_id: nil}}
      assert {:ok, %{level: :read}} = Access.track_access(member, c.track.id)
      assert {:error, {:forbidden, _}} = prompt(member, c.track)

      assert {:error, {:unprocessable, "owner", _}} =
               People.set_project_role(manager, c.project.id, "owner", "read")

      assert {:error, {:forbidden, _}} =
               People.set_project_role(member, c.project.id, "manager", "read")

      assert {:error, :not_found} =
               People.set_project_role(manager, c.project.id, "reader", "read")

      # A project admin manages the project's people, not the machine's controls.
      assert {:ok, _} = People.add_project(manager, c.project.id, "writer")
      assert {:error, :not_found} = Access.project_of(manager, c.project.id)
    end

    test "only an admin removes somebody else, and nobody removes the owner", c do
      manager = insert_user(login: "manager")
      member = insert_user(login: "member")
      insert_project_member(c.project, manager, role: :admin)
      insert_project_member(c.project, member)

      assert {:error, {:forbidden, "Only an admin can remove somebody else."}} =
               People.remove_project(member, c.project.id, "manager")

      assert {:error, {:unprocessable, "owner", _}} =
               People.remove_project(manager, c.project.id, "owner")

      assert {:ok, _} = People.remove_project(manager, c.project.id, "member")
      assert {:error, :not_found} = Access.project_access(member, c.project.id)
    end
  end
end

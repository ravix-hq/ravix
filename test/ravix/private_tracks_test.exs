defmodule Ravix.PrivateTracksTest do
  use Ravix.DataCase, async: true
  import Mimic
  alias Ravix.Accounts.Access
  alias Ravix.{People, Plans, Tracks}
  alias Ravix.Tooling
  alias Ravix.ToolingFixture

  setup do
    owner = insert_user()
    creator = insert_user()
    member = insert_user()
    invited = insert_user()
    joiner = insert_user()
    stranger = insert_user()
    project = insert_project(user: owner, repo_full_name: nil, installation_id: nil)
    insert_project_member(project, creator)
    insert_project_member(project, member)
    insert_project(user: stranger)

    track =
      insert_track(
        project: project,
        visibility: :private,
        created_by: creator.id,
        created_by_login: creator.login,
        title: "Private investigation"
      )

    insert_track_member(track, invited)

    stub(Ravix.Fountain, :client, fn ->
      Ravix.Fountain.Client.new("https://fountain.test", "key")
    end)

    stub(Ravix.MachineCache, :environment, fn _, _ -> {:error, :offline} end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

    %{
      owner: owner,
      creator: creator,
      member: member,
      invited: invited,
      joiner: joiner,
      stranger: stranger,
      project: project,
      track: track
    }
  end

  test "creator, invited member and link joiner enter; project access never bypasses privacy",
       c do
    assert {:ok, link} = People.mint_link(c.creator, c.track.id)
    token = List.last(String.split(link.url, "/"))
    assert {:ok, _} = People.claim_link(c.joiner.id, token)

    for user <- [c.creator, c.invited, c.joiner] do
      assert {:ok, %{track: %{id: id}}} = Access.track_access(user, c.track.id)
      assert id == c.track.id
      assert {:ok, [%{id: ^id, visibility: :private}]} = Tracks.list(user, c.project.id)
      assert {:ok, _} = Tracks.get(user, id)
    end

    for user <- [c.owner, c.member, c.stranger] do
      assert {:error, :not_found} = Access.track_access(user, c.track.id)
      assert {:error, :not_found} = Tracks.get(user, c.track.id)
      assert {:error, :not_found} = Ravix.Terminal.exec(user, c.track.id, %{command: "pwd"})
      assert {:error, :not_found} = Ravix.Previews.status(user, c.track.id)
    end

    for user <- [c.owner, c.member], do: assert({:ok, []} = Tracks.list(user, c.project.id))

    for user <- [c.invited, c.joiner],
        do: assert({:error, :not_found} = Access.project_access(user, c.project.id))

    assert {:ok, people} = People.list(c.creator, c.track.id)

    assert Enum.sort(Enum.map(people, & &1.login)) ==
             Enum.sort([c.creator.login, c.invited.login, c.joiner.login])
  end

  test "owner and project members can be explicitly invited; promotion preserves private seats",
       c do
    assert {:ok, _} = People.add(c.creator, c.track.id, c.owner.login)
    assert {:ok, _} = People.add(c.creator, c.track.id, c.member.login)
    assert {:ok, _} = Access.track_access(c.owner, c.track.id)
    assert {:ok, _} = Access.track_access(c.member, c.track.id)
    assert {:ok, _} = People.add_project(c.owner, c.project.id, c.invited.login)
    assert Access.member?(c.track.id, c.invited.id)
    assert {:ok, _} = People.remove(c.creator, c.track.id, c.member.login)
    assert {:error, :not_found} = Access.track_access(c.member, c.track.id)
  end

  test "only stable creator identity controls visibility and invalid values are bounded", c do
    for user <- [c.owner, c.member, c.invited, c.stranger] do
      assert {:error, :not_found} = Tracks.set_visibility(user, c.track.id, "project")
    end

    renamed = %{c.creator | login: "renamed"}

    assert {:error, {:unprocessable, "visibility", _}} =
             Tracks.set_visibility(renamed, c.track.id, "world")

    Ravix.Hub.subscribe(c.project.id)
    assert {:ok, :project} = Tracks.set_visibility(renamed, c.track.id, "project")
    assert_receive {:hub, %{name: :people}}
    assert {:ok, _} = Access.track_access(c.owner, c.track.id)
    assert {:ok, _} = Access.track_access(c.member, c.track.id)
    assert {:ok, :private} = Tracks.set_visibility(renamed, c.track.id, "private")
    assert_receive {:hub, %{name: :people}}
    assert {:error, :not_found} = Access.track_access(c.owner, c.track.id)
  end

  test "plans and MCP redact private assignments while retaining status", c do
    {:ok, plan} =
      Plans.create(c.owner, c.project.id, %{
        "title" => "Ship",
        "items" => [%{"id" => "secret-work", "title" => "Work"}]
      })

    row = Repo.get!(Ravix.Plans.Item, "secret-work")
    Repo.update!(Ecto.Changeset.change(row, track_id: c.track.id))

    for user <- [c.owner, c.member] do
      assert {:ok, %{items: [item]}} = Plans.get(user, plan.id)
      assert item.track_title == "a private track"
      assert item.private_track
      assert item.status == :in_progress
      refute item.track_id
      refute item.track_url
      refute item.pull
      {principal, _, _} = ToolingFixture.principal(user)

      assert {:ok, %{items: []}} =
               Tooling.call(principal, "list_tracks", %{"project_id" => c.project.id})

      for tool <- ["get_track", "read_track"] do
        assert {:error, :not_found} = Tooling.call(principal, tool, %{"track_id" => c.track.id})
      end

      assert {:ok, %{items: [^item]}} =
               Tooling.call(principal, "get_plan", %{"plan_id" => plan.id})
    end

    assert {:ok, %{items: [%{track_id: id, private_track: false}]}} =
             Plans.get(c.creator, plan.id)

    assert id == c.track.id
    {principal, _, _} = ToolingFixture.principal(c.invited)

    assert {:ok, %{items: [%{id: ^id}]}} =
             Tooling.call(principal, "list_tracks", %{"project_id" => c.project.id})

    assert {:ok, %{id: ^id}} = Tooling.call(principal, "get_track", %{"track_id" => id})
  end
end

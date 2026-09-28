defmodule Ravix.PrivateTracksTest do
  use Ravix.DataCase, async: true
  import Mimic
  alias Ravix.Accounts.Access
  alias Ravix.Fountain.Client
  alias Ravix.People
  alias Ravix.People.Store, as: PeopleStore
  alias Ravix.Plans
  alias Ravix.Tooling
  alias Ravix.Tooling.OAuth
  alias Ravix.Tooling.Tasks
  alias Ravix.ToolingFixture
  alias Ravix.Tracks

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
        sandbox_layout: :dedicated,
        created_by: creator.id,
        created_by_login: creator.login,
        title: "Private investigation"
      )

    insert_track_member(track, invited)

    stub(Ravix.Fountain, :client, fn ->
      Client.new("https://fountain.test", "key")
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
      assert {:error, :not_found} = Ravix.Terminal.status(user, c.track.id)
      assert {:error, :not_found} = Tracks.machine_identity(user, c.track.id)
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
    for user <- [c.invited] do
      assert {:error, {:forbidden, _}} = Tracks.set_visibility(user, c.track.id, "project")
    end

    for user <- [c.owner, c.member, c.stranger] do
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

  for removal <- [:owner, :self] do
    @removal removal
    test "promotion preserves private work but #{@removal} project removal revokes it",
         c do
      guest = c.joiner
      public = insert_track(project: c.project)
      assert {:ok, _} = People.add(c.creator, c.track.id, guest.login)
      assert {:error, :not_found} = Tracks.get(guest, public.id)

      assert {:ok, _} =
               Tracks.prompt(guest, c.track.id, %{
                 prompt: "Before promotion",
                 request_id: Ecto.UUID.generate()
               })

      {_token, session} = insert_session(guest)
      grant = insert_preview_grant(c.track, session)
      assert {:ok, _} = People.add_project(c.owner, c.project.id, guest.login)
      assert Access.member?(c.track.id, guest.id)
      assert {:ok, _} = Tracks.get(guest, c.track.id)
      assert {:ok, _} = Tracks.get(guest, public.id)

      assert {:ok, _} =
               Tracks.prompt(guest, c.track.id, %{
                 prompt: "After promotion",
                 request_id: Ecto.UUID.generate()
               })

      remover = if @removal == :owner, do: c.owner, else: guest
      assert {:ok, _} = People.remove_project(remover, c.project.id, guest.login)
      assert {:error, :not_found} = Access.project_access(guest, c.project.id)
      assert {:error, :not_found} = Tracks.get(guest, public.id)
      refute Access.member?(c.track.id, guest.id)
      assert {:error, :not_found} = Tracks.get(guest, c.track.id)
      assert {:error, :not_found} = Tracks.prompt(guest, c.track.id, %{prompt: "Revoked"})
      refute Repo.get(Ravix.Previews.PreviewGrant, grant.hash)
      assert {:ok, _} = Tracks.get(c.creator, c.track.id)
    end
  end

  test "private management is creator-only even for an invited project owner or link joiner", c do
    assert {:ok, link} = People.mint_link(c.creator, c.track.id)
    assert {:ok, _} = People.claim_link(c.joiner.id, List.last(String.split(link.url, "/")))
    assert {:ok, _} = People.add(c.creator, c.track.id, c.owner.login)

    for user <- [c.invited, c.joiner, c.owner] do
      assert {:error, {:forbidden, _}} = Tracks.rename(user, c.track.id, "No")
      assert {:error, {:forbidden, _}} = Tracks.close(user, c.track.id, force: true)
      assert {:error, {:forbidden, _}} = Tracks.rebuild_machine(user, c.track.id, force: true)
      assert {:error, {:forbidden, _}} = People.add(user, c.track.id, c.stranger.login)
      assert {:error, {:forbidden, _}} = People.remove(user, c.track.id, c.creator.login)
    end

    assert :ok = Tracks.rename(c.creator, c.track.id, "Creator's title")
  end

  test "project-visible sharing remains owner-only even for the stable creator", c do
    track = insert_track(project: c.project, created_by: c.creator.id)
    assert {:error, {:forbidden, _}} = People.add(c.creator, track.id, c.stranger.login)
    assert {:error, {:forbidden, _}} = People.link(c.creator, track.id)
    assert {:error, {:forbidden, _}} = People.mint_link(c.creator, track.id)
    assert {:error, {:forbidden, _}} = People.drop_link(c.creator, track.id)
    assert {:ok, _} = People.add(c.owner, track.id, c.stranger.login)
  end

  test "removing a creator cancels work, invalidates sharing, and exposes only orphan cleanup",
       c do
    assert {:ok, _} = People.remove(c.creator, c.track.id, c.invited.login)
    assert {:ok, link} = People.mint_link(c.creator, c.track.id)
    token = List.last(String.split(link.url, "/"))

    assert {:ok, item} =
             Tracks.prompt(c.creator, c.track.id, %{
               prompt: "Secret work",
               request_id: Ecto.UUID.generate()
             })

    invite =
      insert_track_invite(c.track,
        github_id: "pending-private",
        login: "pending-private",
        invited_by: c.creator.id
      )

    assert {:ok, _} = People.add(c.creator, c.track.id, c.owner.login)
    assert {:error, _} = People.remove(c.owner, c.track.id, invite.login)

    assert Repo.get_by(Ravix.Tracks.TrackInvite,
             track_id: c.track.id,
             github_id: invite.github_id
           )

    assert {:ok, _} = People.remove(c.creator, c.track.id, c.owner.login)
    {_token, session} = insert_session(c.creator)
    grant = insert_preview_grant(c.track, session)
    assert {:ok, 0} = Tracks.orphan_private_count(c.owner, c.project.id)
    assert {:ok, _} = People.remove_project(c.owner, c.project.id, c.creator.login)
    assert {:error, :not_found} = Tracks.get(c.creator, c.track.id)
    assert Repo.get_by!(Ravix.PromptQueue.Item, id: item.id).status == :cancelled

    refute Repo.get_by(Ravix.Tracks.TrackInvite,
             track_id: c.track.id,
             github_id: invite.github_id
           )

    refute Repo.get(Ravix.Previews.PreviewGrant, grant.hash)
    assert :error = People.claim_link(c.stranger.id, token)
    assert {:ok, _} = People.add_project(c.owner, c.project.id, c.creator.login)
    assert {:error, :not_found} = Tracks.get(c.creator, c.track.id)
    assert {:ok, 1} = Tracks.orphan_private_count(c.owner, c.project.id)
    assert {:error, :not_found} = Tracks.orphan_private_count(c.member, c.project.id)
    assert {:error, :not_found} = Tracks.close_orphaned_private(c.member, c.project.id)
    assert {:ok, []} = Tracks.list(c.owner, c.project.id)
    assert {:error, :not_found} = Tracks.get(c.owner, c.track.id)
    assert {:ok, 1} = Tracks.close_orphaned_private(c.owner, c.project.id)
    assert Repo.get!(Ravix.Tracks.Track, c.track.id).sandbox_state == :closing
    assert {:ok, 0} = Tracks.orphan_private_count(c.owner, c.project.id)
    assert {:error, :not_found} = Tracks.get(c.owner, c.track.id)
  end

  test "removed creators disappear from task pagination while other private participants remain",
       c do
    {principal, _, _} = ToolingFixture.principal(c.creator)

    assert {:ok, task} =
             Tasks.send(principal, c.track.id, "private work", "request")

    assert {:ok, %{totalSize: 1}} = Tasks.list(principal, %{})
    assert {:ok, _} = People.remove_project(c.owner, c.project.id, c.creator.login)

    assert {:ok, %{tasks: [], totalSize: 0, nextPageToken: ""}} =
             Tasks.list(principal, %{})

    assert {:error, :not_found} = Tasks.get(principal, task.id)
    assert {:ok, _} = Tracks.get(c.invited, c.track.id)
    assert {:ok, 0} = Tracks.orphan_private_count(c.owner, c.project.id)
    # A fresh explicit share restores only that share, never old creator access.
    other = insert_track(project: c.project)
    assert {:ok, _} = People.add(c.owner, other.id, c.creator.login)
    assert {:ok, [%{id: id}]} = Tracks.list(c.creator, c.project.id)
    assert id == other.id
  end

  test "shared tracks cannot become private or be created private", c do
    shared = insert_track(project: c.project, created_by: c.creator.id)

    error =
      {:error,
       {:conflict, "private_requires_dedicated",
        "Private tracks need their own machine. This track shares the project machine."}}

    assert Tracks.set_visibility(c.creator, shared.id, "private") == error

    assert %{visibility: :project, sandbox_layout: :shared} =
             Repo.get!(Ravix.Tracks.Track, shared.id)

    assert {:ok, :project} = Tracks.set_visibility(c.creator, shared.id, "project")
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> false end)
    reject(Ravix.Fountain, :client, 0)
    assert Tracks.open(c.creator, c.project.id, %{"visibility" => "private"}) == error
    assert {:error, :not_found} = Tracks.set_visibility(c.stranger, shared.id, "private")
  end

  test "project removal revokes project-visible tracks and private creator access",
       c do
    public = insert_track(project: c.project, created_by: c.creator.id)
    assert {:ok, _} = Access.track_access(c.creator, public.id)
    PeopleStore.remove_project_member(c.project.id, c.creator.id)
    assert {:error, :not_found} = Access.track_access(c.creator, public.id)
    assert {:error, :not_found} = Access.track_access(c.creator, c.track.id)
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

    stub(Ravix.Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: nil, has_more: false}}
    end)

    assert {:ok, _} = Tooling.call(principal, "read_track", %{"track_id" => id})
    OAuth.disconnect(c.invited, principal.grant.id)
    assert {:error, :unauthenticated} = Tooling.call(principal, "get_track", %{"track_id" => id})
  end
end

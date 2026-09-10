defmodule Ravix.PeopleTest do
  @moduledoc """
  The membership boundaries, written down.

  There are two, and the tests come in two halves for that reason. A track
  invitation is "help me on this branch" and stops at that row; a project
  invitation is "work on this machine with me" and reaches every row on it.
  What neither reaches is the machine's controls, which is `project_of`'s
  job and not a question the database can answer.

  The half worth reading twice is the interaction: the two grants are
  separate rows, and the assertions below pin down what happens when one
  person has both.

  The first sections are `server/people.test.ts`, the rows; the later ones
  are the routes of `server/people.ts` through the access doors.
  """
  use Ravix.DataCase, async: true
  use Mimic
  alias Ravix.Hub.Event

  alias Ravix.Accounts.Access
  alias Ravix.GitHubFake, as: Fake
  alias Ravix.People
  alias Ravix.Projects.Project
  alias Ravix.Tracks.Track

  setup :verify_on_exit!

  # Removing somebody revokes their preview grants through `Ravix.Previews`;
  # that context is stood in for here, and named tests `expect` the calls.
  setup do
    stub(Ravix.Previews, :revoke, fn _track_id, _user_id -> :ok end)
    stub(Ravix.Previews, :revoke_agent, fn _track_id, _user_id -> :ok end)
    :ok
  end

  defp seed(_context) do
    owner = insert_user(github_id: "1", login: "ana", name: "Ana", avatar_url: nil)
    guest = insert_user(github_id: "2", login: "bo", name: "Bo", avatar_url: nil)
    other = insert_user(github_id: "3", login: "cy", name: "Cy", avatar_url: nil)
    project = insert_project(user: owner, name: "ledger")

    shared =
      insert_track(project: project, slug: "crewe", title: "Crewe", created_by_login: "ana")

    private =
      insert_track(project: project, slug: "selkirk", title: "Selkirk", created_by_login: "ana")

    %{
      owner: owner,
      guest: guest,
      other: other,
      project: project,
      shared: shared,
      private: private
    }
  end

  defp close_track(%Track{id: id}) do
    Repo.update_all(from(t in Track, where: t.id == ^id), set: [closed_at: DateTime.utc_now()])
    :ok
  end

  defp archive_project(%Project{id: id}) do
    Repo.update_all(from(p in Project, where: p.id == ^id),
      set: [archived_at: DateTime.utc_now()]
    )

    :ok
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)
  defp logins(people), do: Enum.map(people, & &1.login)

  # ── who else is in a track ─────────────────────────────────────────

  describe "track membership rows" do
    setup :seed

    test "an invitation reaches one track and stops there", ctx do
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")

      assert People.Store.member?(ctx.shared.id, ctx.guest.id)
      # The other track of the same project is not part of the deal, and
      # this is the assertion that keeps "an invitation is to a branch, not
      # to a machine" true rather than aspirational.
      refute People.Store.member?(ctx.private.id, ctx.guest.id)
      assert ids(People.Store.member_tracks(ctx.guest.id)) == [ctx.shared.id]
    end

    test "somebody who was never invited is in nothing", ctx do
      refute People.Store.member?(ctx.shared.id, ctx.other.id)
      assert People.Store.member_tracks(ctx.other.id) == []
    end

    test "removing somebody removes them, and only them", ctx do
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      People.Store.add_member(ctx.shared.id, ctx.other.id, "owner")
      People.Store.remove_member(ctx.shared.id, ctx.guest.id)

      refute People.Store.member?(ctx.shared.id, ctx.guest.id)
      assert People.Store.member?(ctx.shared.id, ctx.other.id)
    end

    test "removing somebody revokes the preview grants they held on the track", ctx do
      %{id: track_id} = ctx.shared
      %{id: guest_id} = ctx.guest
      People.Store.add_member(track_id, guest_id, "owner")

      expect(Ravix.Previews, :revoke, fn ^track_id, ^guest_id -> :ok end)
      expect(Ravix.Previews, :revoke_agent, fn ^track_id, ^guest_id -> :ok end)
      People.Store.remove_member(track_id, guest_id)
    end

    test "inviting twice is not two seats", ctx do
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      assert length(People.Store.members_of(ctx.shared.id)) == 1
    end

    test "members are listed oldest invitation first", ctx do
      insert_track_member(ctx.shared, ctx.other, created_at: ~U[2026-01-01 00:00:00.000000Z])
      insert_track_member(ctx.shared, ctx.guest, created_at: ~U[2026-01-02 00:00:00.000000Z])
      assert logins(People.Store.members_of(ctx.shared.id)) == ["cy", "bo"]
    end

    test "closing a track takes its membership out of circulation", ctx do
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      close_track(ctx.shared)
      # The row survives (history, and re-opening is not a thing) but the
      # track stops appearing as somewhere they can go.
      assert People.Store.member_tracks(ctx.guest.id) == []
      assert People.Store.member?(ctx.shared.id, ctx.guest.id)
    end
  end

  # ── the invite box ─────────────────────────────────────────────────

  describe "search/2" do
    setup :seed

    test "finds people by login and by name, prefix first", ctx do
      insert_user(login: "joana", name: nil)
      insert_user(login: "anb", name: nil)

      # `ana` is the owner and excluded as the caller; `joana` contains it,
      # `anb` starts with `an` and sorts before it.
      assert logins(People.search(ctx.owner, "an")) == ["anb", "joana"]
      assert "bo" in logins(People.search(ctx.owner, "Bo"))
    end

    test "never suggests the person typing", ctx do
      refute "ana" in logins(People.search(ctx.owner, "ana"))
    end

    test "an empty query is not a directory of the userbase", ctx do
      assert People.search(ctx.owner, "") == []
      assert People.search(ctx.owner, "   ") == []
      assert People.search(ctx.owner, nil) == []
    end

    test "hands back only what GitHub publishes", ctx do
      assert [%{login: "bo", name: "Bo", avatar_url: nil} = person] =
               People.search(ctx.owner, "bo")

      assert Map.keys(person) |> Enum.sort() == [:avatar_url, :login, :name]
    end
  end

  # ── invitations to somebody who is not here yet ────────────────────

  describe "track invitations" do
    setup :seed

    test "an invitation waits on the GitHub account, not on a row we hold", ctx do
      People.Store.add_invite(%{
        track_id: ctx.shared.id,
        github_id: "9001",
        login: "dana",
        avatar_url: nil,
        invited_by: "owner"
      })

      assert Enum.map(People.Store.invites_of(ctx.shared.id), & &1.login) == ["dana"]
      # Nobody has joined: an invitation is a promise, not access.
      assert People.Store.members_of(ctx.shared.id) == []

      dana = insert_user(github_id: "9001", login: "dana")
      joined = People.Store.claim_invites(dana.id, "9001")

      assert ids(joined.tracks) == [ctx.shared.id]
      assert joined.projects == []
      assert People.Store.member?(ctx.shared.id, dana.id)
      assert People.Store.invites_of(ctx.shared.id) == []
    end

    test "re-inviting the same account refreshes the name it is shown with", ctx do
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana", avatar_url: nil)

      People.Store.add_invite(%{
        track_id: ctx.shared.id,
        github_id: "9001",
        login: "dana-codes",
        avatar_url: "https://a/9001",
        invited_by: "owner"
      })

      assert [%{github_id: "9001", login: "dana-codes", avatar_url: "https://a/9001"}] =
               People.Store.invites_of(ctx.shared.id)
    end

    test "a renamed login still finds them; a recycled one does not", ctx do
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana")

      # They changed their name between the invitation and the sign-in.
      renamed = insert_user(github_id: "9001", login: "dana-codes")
      assert length(People.Store.claim_invites(renamed.id, "9001").tracks) == 1

      # And somebody else who later takes the *old* name gets nothing. This
      # is the whole reason the invitation is keyed on the numeric id.
      insert_track_invite(ctx.shared, github_id: "9002", login: "eli")
      impostor = insert_user(github_id: "9999", login: "eli")
      assert People.Store.claim_invites(impostor.id, "9999").tracks == []
      refute People.Store.member?(ctx.shared.id, impostor.id)
    end

    test "an invitation to a track that closed meanwhile grants nothing", ctx do
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana")
      close_track(ctx.shared)

      dana = insert_user(github_id: "9001", login: "dana")
      assert People.Store.claim_invites(dana.id, "9001").tracks == []
      refute People.Store.member?(ctx.shared.id, dana.id)
      # And it does not linger to be claimed by a later sign-in either.
      assert People.Store.invites_of(ctx.shared.id) == []
    end

    test "an invitation can be withdrawn before it is taken up", ctx do
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana")

      assert People.Store.remove_invite_by_login(ctx.shared.id, "DANA")
      assert People.Store.invites_of(ctx.shared.id) == []
      refute People.Store.remove_invite_by_login(ctx.shared.id, "dana")
    end
  end

  # ── the link ───────────────────────────────────────────────────────

  describe "track link rows" do
    setup :seed

    test "minting a link revokes the one that was out", ctx do
      People.Store.put_link(ctx.shared.id, "hash-one", "owner", 60_000)
      People.Store.put_link(ctx.shared.id, "hash-two", "owner", 60_000)

      # One row per track, so there is no "old link" left to work.
      assert People.Store.track_for_link("hash-one") == nil
      assert People.Store.track_for_link("hash-two").id == ctx.shared.id
    end

    test "a link stops working when revoked, expired, or its track closes", ctx do
      People.Store.put_link(ctx.shared.id, "live", "owner", 60_000)
      assert People.Store.track_for_link("live").id == ctx.shared.id

      assert %{created_at: %DateTime{}, expires_at: %DateTime{}} =
               People.Store.link_of(ctx.shared.id)

      People.Store.drop_link(ctx.shared.id)
      assert People.Store.track_for_link("live") == nil
      assert People.Store.link_of(ctx.shared.id) == nil

      People.Store.put_link(ctx.shared.id, "stale", "owner", -1)
      assert People.Store.track_for_link("stale") == nil

      People.Store.put_link(ctx.private.id, "doomed", "owner", 60_000)
      close_track(ctx.private)
      assert People.Store.track_for_link("doomed") == nil
    end

    test "an unknown token opens nothing" do
      assert People.Store.track_for_link("never-minted") == nil
    end
  end

  # ── the wider grain: the whole project ─────────────────────────────

  describe "project membership rows" do
    setup :seed

    test "a project membership reaches every track on it, including later ones", ctx do
      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")

      assert People.Store.project_member?(ctx.project.id, ctx.guest.id)
      # Both of the tracks that existed when they were let in...
      assert {:ok, %{role: :member}} = Access.track_access(ctx.guest, ctx.shared.id)
      assert {:ok, %{role: :member}} = Access.track_access(ctx.guest, ctx.private.id)
      # ...and the one cut afterwards, which is the difference between this
      # and sending two track invitations. Nothing has to be written when it
      # opens.
      later = insert_track(project: ctx.project, slug: "dover")
      assert {:ok, %{role: :member}} = Access.track_access(ctx.guest, later.id)
    end

    test "a project membership is not a track membership", ctx do
      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")

      # The two tables are what the rail reads to decide which controls to
      # draw, so a project member must not turn up as a track member of
      # anything: they reach it through `track_access`'s second question.
      refute People.Store.member?(ctx.shared.id, ctx.guest.id)
      assert People.Store.member_tracks(ctx.guest.id) == []
      assert ids(People.Store.member_projects(ctx.guest.id)) == [ctx.project.id]
    end

    test "the wider grant replaces the narrower ones, so nobody holds two", ctx do
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")

      # One person, one grade of access to a project. Two rows granting the
      # same person the same track by different routes is a state no list
      # can render honestly, and a revoke that left one behind would leave
      # access nothing explained.
      assert People.Store.project_member?(ctx.project.id, ctx.guest.id)
      refute People.Store.member?(ctx.shared.id, ctx.guest.id)

      # So removing them from the project is the whole revoke, which is the
      # surprising half and the reason the dialog says it out loud.
      People.Store.remove_project_member(ctx.project.id, ctx.guest.id)
      assert People.Store.member_projects(ctx.guest.id) == []
      assert People.Store.member_tracks(ctx.guest.id) == []
      assert {:error, :not_found} = Access.track_access(ctx.guest, ctx.shared.id)
    end

    test "removing somebody from a project revokes their grants on every open track", ctx do
      %{id: shared_id} = ctx.shared
      %{id: private_id} = ctx.private
      %{id: guest_id} = ctx.guest
      closed = insert_track(project: ctx.project, slug: "closed")
      close_track(closed)
      People.Store.add_project_member(ctx.project.id, guest_id, "owner")

      revoked = :ets.new(:revoked, [:public, :bag])

      expect(Ravix.Previews, :revoke, 2, fn t, ^guest_id -> :ets.insert(revoked, {:revoke, t}) end)

      expect(Ravix.Previews, :revoke_agent, 2, fn t, ^guest_id ->
        :ets.insert(revoked, {:agent, t})
      end)

      People.Store.remove_project_member(ctx.project.id, guest_id)

      assert Enum.sort(:ets.lookup(revoked, :revoke)) ==
               Enum.sort([{:revoke, shared_id}, {:revoke, private_id}])

      assert Enum.sort(:ets.lookup(revoked, :agent)) ==
               Enum.sort([{:agent, shared_id}, {:agent, private_id}])
    end

    test "the owner is never a member of their own project", ctx do
      insert_project_invite(ctx.project, github_id: "1", login: "ana", invited_by: "somebody")

      # Ownership is the stronger claim and it is a column on the project
      # rather than a row here, so claiming an invitation to your own
      # project writes nothing, and cannot end with the owner able to lose
      # themselves by leaving.
      assert People.Store.claim_invites(ctx.owner.id, "1").projects == []
      refute People.Store.project_member?(ctx.project.id, ctx.owner.id)
      assert People.Store.project_members_of(ctx.project.id) == []
      assert People.Store.project_invites_of(ctx.project.id) == []
    end

    test "an archived project is not somewhere to arrive", ctx do
      insert_project_invite(ctx.project, github_id: "9001", login: "dana")
      archive_project(ctx.project)

      dana = insert_user(github_id: "9001", login: "dana")
      assert People.Store.claim_invites(dana.id, "9001").projects == []
      refute People.Store.project_member?(ctx.project.id, dana.id)
      assert People.Store.project_invites_of(ctx.project.id) == []
    end
  end

  describe "project invitations" do
    setup :seed

    test "a project invitation waits on the GitHub account, like a track's", ctx do
      People.Store.add_project_invite(%{
        project_id: ctx.project.id,
        github_id: "9001",
        login: "dana",
        avatar_url: nil,
        invited_by: "owner"
      })

      assert Enum.map(People.Store.project_invites_of(ctx.project.id), & &1.login) == ["dana"]
      assert People.Store.project_members_of(ctx.project.id) == []

      dana = insert_user(github_id: "9001", login: "dana")
      joined = People.Store.claim_invites(dana.id, "9001")

      assert ids(joined.projects) == [ctx.project.id]
      assert People.Store.project_member?(ctx.project.id, dana.id)
      assert People.Store.project_invites_of(ctx.project.id) == []
    end

    test "a sign-in holding both invitations ends up in the project, once", ctx do
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana")
      insert_project_invite(ctx.project, github_id: "9001", login: "dana")

      dana = insert_user(github_id: "9001", login: "dana")
      joined = People.Store.claim_invites(dana.id, "9001")

      # Projects are claimed first, so the track invitation grants nothing
      # they do not already have and is dropped rather than written;
      # otherwise the order of two rows would decide whether somebody ends
      # up at one grade or two.
      assert length(joined.projects) == 1
      assert joined.tracks == []
      assert People.Store.project_member?(ctx.project.id, dana.id)
      refute People.Store.member?(ctx.shared.id, dana.id)
      # And neither invitation is left behind to be claimed a second time.
      assert People.Store.invites_of(ctx.shared.id) == []
      assert People.Store.project_invites_of(ctx.project.id) == []
    end

    test "a project invitation supersedes a pending track one on the same project", ctx do
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana")
      elsewhere = insert_track()
      insert_track_invite(elsewhere, github_id: "9001", login: "dana")

      People.Store.add_project_invite(%{
        project_id: ctx.project.id,
        github_id: "9001",
        login: "dana",
        avatar_url: nil,
        invited_by: "owner"
      })

      # Otherwise the track's people list keeps a pending row whose remove
      # control cancels an invitation that was already superseded: a
      # control that reads as taking access away and does not.
      assert People.Store.invites_of(ctx.shared.id) == []
      assert Enum.map(People.Store.project_invites_of(ctx.project.id), & &1.login) == ["dana"]
      assert People.Store.has_project_invite?(ctx.project.id, "9001")

      # Only on that project, though: an invitation to a track of somebody
      # else's machine is a different decision entirely.
      refute People.Store.has_project_invite?("nope", "9001")
      assert Enum.map(People.Store.invites_of(elsewhere.id), & &1.login) == ["dana"]
    end

    test "a project invitation can be withdrawn before it is taken up", ctx do
      insert_project_invite(ctx.project, github_id: "9001", login: "dana")

      assert People.Store.remove_project_invite_by_login(ctx.project.id, "DANA")
      assert People.Store.project_invites_of(ctx.project.id) == []
      refute People.Store.remove_project_invite_by_login(ctx.project.id, "dana")
    end
  end

  describe "project link rows" do
    setup :seed

    test "a project link behaves like a track's, and the two do not collide", ctx do
      People.Store.put_project_link(ctx.project.id, "p-one", "owner", 60_000)
      People.Store.put_project_link(ctx.project.id, "p-two", "owner", 60_000)
      # One row per project, so minting is the revoke here too.
      assert People.Store.project_for_link("p-one") == nil
      assert People.Store.project_for_link("p-two").id == ctx.project.id
      assert %{created_at: %DateTime{}} = People.Store.project_link_of(ctx.project.id)

      People.Store.drop_project_link(ctx.project.id)
      assert People.Store.project_for_link("p-two") == nil
      assert People.Store.project_link_of(ctx.project.id) == nil

      People.Store.put_project_link(ctx.project.id, "stale", "owner", -1)
      assert People.Store.project_for_link("stale") == nil

      # `/j/:token` tries both tables, so a token that opens one must not
      # open the other; otherwise a track link would quietly hand over the
      # whole machine.
      People.Store.put_link(ctx.shared.id, "t-token", "owner", 60_000)
      People.Store.put_project_link(ctx.project.id, "p-token", "owner", 60_000)
      assert People.Store.project_for_link("t-token") == nil
      assert People.Store.track_for_link("p-token") == nil
    end

    test "an archived project's link opens nothing, and its people go with it", ctx do
      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")
      People.Store.put_project_link(ctx.project.id, "live", "owner", 60_000)

      archive_project(ctx.project)

      assert People.Store.project_for_link("live") == nil
      # The row survives (this is an archive, not a delete) but the project
      # stops appearing as somewhere they can go, exactly as a closed track
      # does.
      assert People.Store.member_projects(ctx.guest.id) == []
      assert People.Store.project_member?(ctx.project.id, ctx.guest.id)
    end
  end

  # ── what you have not read ─────────────────────────────────────────

  describe "read markers" do
    setup :seed

    test "a read is per person per track, and the latest look wins", ctx do
      assert People.Store.last_read_of(ctx.shared.id, ctx.guest.id) == nil

      first = ~U[2026-03-01 10:00:00.000000Z]
      later = ~U[2026-03-01 11:00:00.000000Z]
      People.Store.mark_read(ctx.shared.id, ctx.guest.id, first)
      People.Store.mark_read(ctx.shared.id, ctx.guest.id, later)
      People.Store.mark_read(ctx.private.id, ctx.guest.id, first)
      People.Store.mark_read(ctx.shared.id, ctx.owner.id, first)

      assert People.Store.last_read_of(ctx.shared.id, ctx.guest.id) == later
      assert People.Store.last_read_of(ctx.shared.id, ctx.owner.id) == first

      assert People.Store.reads_of(ctx.guest.id, ctx.project.id) == %{
               ctx.shared.id => later,
               ctx.private.id => first
             }

      # Another project's tracks are not in the answer.
      assert People.Store.reads_of(ctx.guest.id, insert_project().id) == %{}
    end

    test "marking read defaults to now", ctx do
      People.Store.mark_read(ctx.shared.id, ctx.guest.id)
      assert %DateTime{} = seen = People.Store.last_read_of(ctx.shared.id, ctx.guest.id)
      assert DateTime.diff(DateTime.utc_now(), seen, :second) < 5
    end
  end

  # ── the routes: a track's people ───────────────────────────────────

  describe "list/2 and people_of/3" do
    setup :seed

    test "owner first, then project members, then track members, then pending", ctx do
      People.Store.add_project_member(ctx.project.id, ctx.other.id, "owner")
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana", avatar_url: "https://a/d")

      assert {:ok, people} = People.list(ctx.owner, ctx.shared.id)

      assert people == [
               %{login: "ana", name: "Ana", avatar_url: nil},
               %{login: "cy", name: "Cy", avatar_url: nil, via: :project},
               %{login: "bo", name: "Bo", avatar_url: nil, via: :track},
               %{login: "dana", name: nil, avatar_url: "https://a/d", pending: true}
             ]

      # A member sees the same list.
      assert {:ok, ^people} = People.list(ctx.guest, ctx.shared.id)
    end

    test "people_by_track/3 gives every named track the list people_of/3 would", ctx do
      People.Store.add_project_member(ctx.project.id, ctx.other.id, "owner")
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana", avatar_url: "https://a/d")

      ids = [ctx.shared.id, ctx.private.id]
      batched = People.Store.people_by_track(ids, ctx.owner.id, ctx.project.id)

      assert Map.keys(batched) |> Enum.sort() == Enum.sort(ids)

      for id <- ids do
        assert batched[id] == People.Store.people_of(id, ctx.owner.id, ctx.project.id)
      end

      # The track with nobody of its own still gets the project's people.
      assert batched[ctx.private.id] == [
               %{login: "ana", name: "Ana", avatar_url: nil},
               %{login: "cy", name: "Cy", avatar_url: nil, via: :project}
             ]

      assert People.Store.people_by_track([], ctx.owner.id, ctx.project.id) == %{}
    end

    test "somebody who is both is shown once, as a project member", ctx do
      insert_track_member(ctx.shared, ctx.guest)
      insert_project_member(ctx.project, ctx.guest)

      assert {:ok, people} = People.list(ctx.owner, ctx.shared.id)

      assert Enum.filter(people, &(&1.login == "bo")) == [
               %{login: "bo", name: "Bo", avatar_url: nil, via: :project}
             ]
    end

    test "a stranger, a closed track and an archived project are not found", ctx do
      assert {:error, :not_found} = People.list(ctx.other, ctx.shared.id)
      assert {:error, :not_found} = People.list(ctx.owner, "nope")

      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      close_track(ctx.shared)
      assert {:error, :not_found} = People.list(ctx.guest, ctx.shared.id)

      archive_project(ctx.project)
      assert {:error, :not_found} = People.list(ctx.owner, ctx.private.id)
    end

    test "responses contain only public profile fields", ctx do
      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")

      assert {:ok, people} = People.list(ctx.guest, ctx.shared.id)
      assert length(people) == 2

      for person <- people do
        expected =
          if person[:via],
            do: [:avatar_url, :login, :name, :via],
            else: [:avatar_url, :login, :name]

        assert Enum.sort(Map.keys(person)) == expected
      end

      assert {:ok, people} = People.list_project(ctx.guest, ctx.project.id)
      assert length(people) == 2

      for person <- people,
          do: assert(Enum.sort(Map.keys(person)) == [:avatar_url, :login, :name])
    end
  end

  describe "add/3" do
    setup :seed

    setup do
      # Nobody on GitHub but @dana, and the App is configured.
      Fake.install([
        {"GET", "/users/dana",
         fn conn ->
           Req.Test.json(conn, %{
             id: 9001,
             login: "dana",
             name: "Dana",
             avatar_url: "https://a/9001"
           })
         end},
        {"GET", "/users/nobody", {404, %{message: "Not Found"}}},
        {"GET", "/users/broken", {401, %{message: "Bad credentials"}}}
      ])

      stub(Ravix.Config, :github, fn -> Fake.app() end)
      :ok
    end

    test "somebody who has signed in here joins immediately, and the project hears", ctx do
      %{id: track_id} = ctx.shared
      Ravix.Hub.subscribe(ctx.project.id)

      assert {:ok, people} = People.add(ctx.owner, track_id, "@Bo")
      assert logins(people) == ["ana", "bo"]
      assert People.Store.member?(track_id, ctx.guest.id)
      assert_receive {:hub, %Event{name: :people, track_id: ^track_id}}
      # Invited as a person, not a login.
      assert People.Store.invites_of(track_id) == []
    end

    test "somebody who has not signed in is invited on GitHub's account", ctx do
      assert {:ok, people} = People.add(ctx.owner, ctx.shared.id, "dana")

      assert [%{login: "dana", name: nil, avatar_url: "https://a/9001", pending: true}] =
               tl(people)

      assert [%{github_id: "9001", login: "dana"}] = People.Store.invites_of(ctx.shared.id)
      assert People.Store.members_of(ctx.shared.id) == []
    end

    test "a stranger cannot be invited", ctx do
      assert {:error, {:unprocessable, "no_such_user", "There is no GitHub user called @nobody."}} =
               People.add(ctx.owner, ctx.shared.id, "nobody")

      assert {:error, {:unprocessable, "no_login", _}} = People.add(ctx.owner, ctx.shared.id, "")

      assert {:error, {:unprocessable, "no_login", _}} =
               People.add(ctx.owner, ctx.shared.id, " @ ")

      assert {:error, {:unprocessable, "no_login", _}} = People.add(ctx.owner, ctx.shared.id, nil)
      assert People.Store.invites_of(ctx.shared.id) == []
    end

    test "GitHub's refusal comes back as GitHub's error", ctx do
      assert {:error, %Ravix.GitHub.Error{status: 401}} =
               People.add(ctx.owner, ctx.shared.id, "broken")
    end

    test "without a GitHub App nobody new can be looked up, but accounts here still join", ctx do
      stub(Ravix.Config, :github, fn -> nil end)
      assert {:error, {:unavailable, _}} = People.add(ctx.owner, ctx.shared.id, "dana")
      assert {:ok, _} = People.add(ctx.owner, ctx.shared.id, "bo")
    end

    test "the owner is already in every track", ctx do
      assert {:error, {:unprocessable, "already_owner", _}} =
               People.add(ctx.owner, ctx.shared.id, "ana")
    end

    test "somebody in the whole project, or on their way in, is refused rather than ignored",
         ctx do
      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")

      assert {:error, {:unprocessable, "already_in_project", message}} =
               People.add(ctx.owner, ctx.shared.id, "bo")

      assert message =~ "@bo is in this whole project already"
      refute People.Store.member?(ctx.shared.id, ctx.guest.id)

      insert_project_invite(ctx.project, github_id: "9001", login: "dana")

      assert {:error, {:unprocessable, "already_in_project", message}} =
               People.add(ctx.owner, ctx.shared.id, "dana")

      assert message =~ "@dana is already invited to this whole project"
      assert People.Store.invites_of(ctx.shared.id) == []
    end

    test "only the owner invites", ctx do
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      assert {:error, {:forbidden, message}} = People.add(ctx.guest, ctx.shared.id, "cy")
      assert message =~ "invite people to a track"
      assert {:error, :not_found} = People.add(ctx.other, ctx.shared.id, "bo")
    end
  end

  describe "remove/3" do
    setup :seed

    test "the owner withdraws an invitation nobody took up", ctx do
      %{id: track_id} = ctx.shared
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana")
      Ravix.Hub.subscribe(ctx.project.id)

      assert {:ok, people} = People.remove(ctx.owner, track_id, "Dana")
      assert logins(people) == ["ana"]
      assert People.Store.invites_of(track_id) == []
      assert_receive {:hub, %Event{name: :people, track_id: ^track_id}}
    end

    test "the owner removes a member, case-insensitively and with or without the @", ctx do
      %{id: track_id} = ctx.shared
      %{id: guest_id} = ctx.guest
      People.Store.add_member(track_id, guest_id, "owner")
      People.Store.add_member(track_id, ctx.other.id, "owner")

      expect(Ravix.Previews, :revoke, fn ^track_id, ^guest_id -> :ok end)
      expect(Ravix.Previews, :revoke_agent, fn ^track_id, ^guest_id -> :ok end)

      assert {:ok, people} = People.remove(ctx.owner, track_id, "@BO")
      assert logins(people) == ["ana", "cy"]
      refute People.Store.member?(track_id, guest_id)
    end

    test "a member may leave, and gets no list back", ctx do
      %{id: track_id} = ctx.shared
      People.Store.add_member(track_id, ctx.guest.id, "owner")
      Ravix.Hub.subscribe(ctx.project.id)

      assert {:ok, :left} = People.remove(ctx.guest, track_id, "bo")
      refute People.Store.member?(track_id, ctx.guest.id)
      assert_receive {:hub, %Event{name: :people, track_id: ^track_id}}
      assert {:error, :not_found} = People.list(ctx.guest, track_id)
    end

    test "a member may not remove somebody else, or withdraw an invitation", ctx do
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      People.Store.add_member(ctx.shared.id, ctx.other.id, "owner")
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana")

      assert {:error, {:forbidden, "Only the owner of this project can remove somebody else."}} =
               People.remove(ctx.guest, ctx.shared.id, "cy")

      # An invitation is not a person, so a member asking is told there is
      # nobody by that name, and the invitation stays.
      assert {:error, :not_found} = People.remove(ctx.guest, ctx.shared.id, "dana")
      assert length(People.Store.invites_of(ctx.shared.id)) == 1
      assert People.Store.member?(ctx.shared.id, ctx.other.id)
    end

    test "nobody by that name is not found", ctx do
      assert {:error, :not_found} = People.remove(ctx.owner, ctx.shared.id, "zed")
      # Somebody who exists but is not on the track is a no-op removal.
      assert {:ok, people} = People.remove(ctx.owner, ctx.shared.id, "cy")
      assert logins(people) == ["ana"]
    end

    test "somebody here by way of the project is not this dialog's to remove", ctx do
      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")

      assert {:error, {:conflict, "in_whole_project", message}} =
               People.remove(ctx.owner, ctx.shared.id, "bo")

      assert message =~
               "@bo is in this whole project, not just this track. Remove them from the project's people"

      assert {:error, {:conflict, "in_whole_project", message}} =
               People.remove(ctx.guest, ctx.shared.id, "bo")

      assert message =~ "You are in this whole project, not just this track. Leave the project"
      assert People.Store.project_member?(ctx.project.id, ctx.guest.id)
    end

    test "a stranger is not found", ctx do
      assert {:error, :not_found} = People.remove(ctx.other, ctx.shared.id, "bo")
    end
  end

  # ── the routes: one level up ───────────────────────────────────────

  describe "list_project/2, add_project/3 and remove_project/3" do
    setup :seed

    setup do
      Fake.install([
        {"GET", "/users/dana",
         fn conn ->
           Req.Test.json(conn, %{id: 9001, login: "dana", name: nil, avatar_url: nil})
         end}
      ])

      stub(Ravix.Config, :github, fn -> Fake.app() end)
      :ok
    end

    test "the project's people are the owner, its members and its pending, never track members",
         ctx do
      People.Store.add_member(ctx.shared.id, ctx.other.id, "owner")
      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")
      insert_project_invite(ctx.project, github_id: "9001", login: "dana")

      assert {:ok, people} = People.list_project(ctx.owner, ctx.project.id)

      assert people == [
               %{login: "ana", name: "Ana", avatar_url: nil},
               %{login: "bo", name: "Bo", avatar_url: nil},
               %{login: "dana", name: nil, avatar_url: nil, pending: true}
             ]

      assert {:ok, ^people} = People.list_project(ctx.guest, ctx.project.id)
      # A track member is not in the project, and cannot read its list.
      assert {:error, :not_found} = People.list_project(ctx.other, ctx.project.id)
    end

    test "inviting to the project is a promotion, and the whole rail hears", ctx do
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      Ravix.Hub.subscribe(ctx.project.id)

      assert {:ok, people} = People.add_project(ctx.owner, ctx.project.id, "bo")
      assert logins(people) == ["ana", "bo"]
      assert People.Store.project_member?(ctx.project.id, ctx.guest.id)
      refute People.Store.member?(ctx.shared.id, ctx.guest.id)
      # The project's event names no track: it changed who is on every one
      # of them, and a page showing any of them has to act on it.
      assert_receive {:hub, %Event{name: :people, track_id: nil}}
    end

    test "inviting somebody not here yet waits on GitHub and drops their track invitations",
         ctx do
      insert_track_invite(ctx.shared, github_id: "9001", login: "dana")

      assert {:ok, people} = People.add_project(ctx.owner, ctx.project.id, "dana")
      assert [%{login: "dana", pending: true}] = tl(people)
      assert People.Store.invites_of(ctx.shared.id) == []
      assert People.Store.has_project_invite?(ctx.project.id, "9001")
    end

    test "the owner, a member, and a stranger", ctx do
      assert {:error, {:unprocessable, "already_owner", "That is the owner of this project."}} =
               People.add_project(ctx.owner, ctx.project.id, "ana")

      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")
      assert {:error, {:forbidden, message}} = People.add_project(ctx.guest, ctx.project.id, "cy")
      assert message =~ "invite people to a project"
      assert {:error, :not_found} = People.add_project(ctx.other, ctx.project.id, "bo")
    end

    test "removing from the project takes every track with it", ctx do
      %{id: guest_id} = ctx.guest
      People.Store.add_member(ctx.private.id, guest_id, "owner")
      People.Store.add_project_member(ctx.project.id, guest_id, "owner")
      Ravix.Hub.subscribe(ctx.project.id)

      expect(Ravix.Previews, :revoke, 2, fn _track, ^guest_id -> :ok end)
      expect(Ravix.Previews, :revoke_agent, 2, fn _track, ^guest_id -> :ok end)

      assert {:ok, people} = People.remove_project(ctx.owner, ctx.project.id, "@Bo")
      assert logins(people) == ["ana"]
      assert_receive {:hub, %Event{name: :people}}
      assert {:error, :not_found} = Access.track_access(ctx.guest, ctx.private.id)
      assert {:error, :not_found} = Access.track_access(ctx.guest, ctx.shared.id)
    end

    test "withdrawing a project invitation, and leaving", ctx do
      insert_project_invite(ctx.project, github_id: "9001", login: "dana")
      assert {:ok, people} = People.remove_project(ctx.owner, ctx.project.id, "DANA")
      assert logins(people) == ["ana"]
      assert People.Store.project_invites_of(ctx.project.id) == []

      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")
      People.Store.add_project_member(ctx.project.id, ctx.other.id, "owner")

      assert {:error, {:forbidden, _}} = People.remove_project(ctx.guest, ctx.project.id, "cy")
      assert {:error, :not_found} = People.remove_project(ctx.guest, ctx.project.id, "zed")
      assert {:ok, :left} = People.remove_project(ctx.guest, ctx.project.id, "bo")
      refute People.Store.project_member?(ctx.project.id, ctx.guest.id)
      assert {:error, :not_found} = People.list_project(ctx.guest, ctx.project.id)
    end
  end

  # ── the routes: links ──────────────────────────────────────────────

  describe "track links" do
    setup :seed

    setup do
      stub(Ravix.Config, :public_url, fn -> "https://ravix.test" end)
      :ok
    end

    test "only the owner sees whether a link is out, and never the link itself", ctx do
      assert {:ok, nil} = People.link(ctx.owner, ctx.shared.id)

      assert {:ok,
              %{url: "https://ravix.test/j/" <> token, created_at: created, expires_at: expires}} =
               People.mint_link(ctx.owner, ctx.shared.id)

      assert byte_size(token) > 20
      assert DateTime.diff(expires, created, :millisecond) == 7 * 24 * 60 * 60 * 1000

      assert {:ok, %{url: nil, created_at: ^created, expires_at: ^expires}} =
               People.link(ctx.owner, ctx.shared.id)

      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      assert {:error, {:forbidden, _}} = People.link(ctx.guest, ctx.shared.id)
      assert {:error, {:forbidden, _}} = People.mint_link(ctx.guest, ctx.shared.id)
      assert {:error, {:forbidden, _}} = People.drop_link(ctx.guest, ctx.shared.id)
      assert {:error, :not_found} = People.mint_link(ctx.other, ctx.shared.id)
    end

    test "a link admits whoever opens it to that track, and lands them on it", ctx do
      %{id: track_id} = ctx.shared
      assert {:ok, %{url: url}} = People.mint_link(ctx.owner, track_id)
      token = url |> String.split("/j/") |> List.last()
      Ravix.Hub.subscribe(ctx.project.id)

      assert {:ok, "/p/#{ctx.project.id}/t/#{track_id}"} == People.claim_link(ctx.other.id, token)
      assert People.Store.member?(track_id, ctx.other.id)
      assert_receive {:hub, %Event{name: :people, track_id: ^track_id}}
      # Twice is still one seat, and the owner opening their own link writes nothing.
      assert {:ok, _} = People.claim_link(ctx.other.id, token)
      assert {:ok, _} = People.claim_link(ctx.owner.id, token)
      assert logins(People.Store.members_of(track_id)) == ["cy"]
    end

    test "link_target/1 says what a link opens without opening it", ctx do
      %{id: track_id} = ctx.shared
      assert {:ok, %{url: url}} = People.mint_link(ctx.owner, track_id)
      token = url |> String.split("/j/") |> List.last()

      assert {:ok, target} = People.link_target(token)
      assert target.kind == :track
      assert target.track == Repo.get!(Ravix.Tracks.Track, track_id).title
      assert target.project == ctx.project.name
      assert target.invited_by == ctx.owner.login

      # The whole point: reading a link is not taking it (#16).
      refute People.Store.member?(track_id, ctx.other.id)
    end

    test "link_target/1 refuses a link that is gone, and says nothing about which", ctx do
      assert {:ok, %{url: url}} = People.mint_link(ctx.owner, ctx.shared.id)
      token = url |> String.split("/j/") |> List.last()
      assert {:ok, _} = People.link_target(token)

      # Minting again *is* the revoke, so the previous token stops describing
      # anything -- the same answer a token that was never real gets.
      assert {:ok, _} = People.mint_link(ctx.owner, ctx.shared.id)
      assert People.link_target(token) == :error
      assert People.link_target("never-real") == :error
    end

    test "somebody already in the whole project gets no track row from a link", ctx do
      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")
      assert {:ok, %{url: url}} = People.mint_link(ctx.owner, ctx.shared.id)
      token = url |> String.split("/j/") |> List.last()

      assert {:ok, _} = People.claim_link(ctx.guest.id, token)
      refute People.Store.member?(ctx.shared.id, ctx.guest.id)
    end

    test "minting replaces, dropping revokes, and people who came in stay", ctx do
      assert {:ok, %{url: first}} = People.mint_link(ctx.owner, ctx.shared.id)
      first = first |> String.split("/j/") |> List.last()
      assert {:ok, _} = People.claim_link(ctx.guest.id, first)

      assert {:ok, %{url: second}} = People.mint_link(ctx.owner, ctx.shared.id)
      second = second |> String.split("/j/") |> List.last()
      assert :error = People.claim_link(ctx.other.id, first)

      assert :ok = People.drop_link(ctx.owner, ctx.shared.id)
      assert {:ok, nil} = People.link(ctx.owner, ctx.shared.id)
      assert :error = People.claim_link(ctx.other.id, second)
      assert People.Store.member?(ctx.shared.id, ctx.guest.id)
    end

    test "an unknown token, a closed track and an archived project open nothing", ctx do
      assert :error = People.claim_link(ctx.guest.id, "never-minted")

      assert {:ok, %{url: url}} = People.mint_link(ctx.owner, ctx.shared.id)
      token = url |> String.split("/j/") |> List.last()
      close_track(ctx.shared)
      assert :error = People.claim_link(ctx.guest.id, token)

      assert {:ok, %{url: url}} = People.mint_link(ctx.owner, ctx.private.id)
      token = url |> String.split("/j/") |> List.last()
      archive_project(ctx.project)
      assert :error = People.claim_link(ctx.guest.id, token)
      refute People.Store.member?(ctx.private.id, ctx.guest.id)
    end
  end

  describe "project links" do
    setup :seed

    setup do
      stub(Ravix.Config, :public_url, fn -> "https://ravix.test" end)
      :ok
    end

    test "a project link lasts two days and is the owner's alone", ctx do
      assert {:ok, nil} = People.project_link(ctx.owner, ctx.project.id)

      assert {:ok, %{url: "https://ravix.test/j/" <> _, created_at: created, expires_at: expires}} =
               People.mint_project_link(ctx.owner, ctx.project.id)

      assert DateTime.diff(expires, created, :millisecond) == 2 * 24 * 60 * 60 * 1000
      assert {:ok, %{url: nil}} = People.project_link(ctx.owner, ctx.project.id)

      People.Store.add_project_member(ctx.project.id, ctx.guest.id, "owner")
      assert {:error, {:forbidden, _}} = People.project_link(ctx.guest, ctx.project.id)
      assert {:error, {:forbidden, _}} = People.mint_project_link(ctx.guest, ctx.project.id)
      assert {:error, {:forbidden, _}} = People.drop_project_link(ctx.guest, ctx.project.id)
      assert {:error, :not_found} = People.project_link(ctx.other, ctx.project.id)

      assert :ok = People.drop_project_link(ctx.owner, ctx.project.id)
      assert {:ok, nil} = People.project_link(ctx.owner, ctx.project.id)
    end

    test "link_target/1 on a project link names the project and not a track", ctx do
      assert {:ok, %{url: url}} = People.mint_project_link(ctx.owner, ctx.project.id)
      token = url |> String.split("/j/") |> List.last()

      assert {:ok, target} = People.link_target(token)
      assert target.kind == :project
      assert target.project == ctx.project.name
      assert target.track == nil
      assert target.invited_by == ctx.owner.login

      refute People.Store.project_member?(ctx.project.id, ctx.other.id)

      # An archived project has nothing to join, and says so the same way a
      # token that was never real does.
      archive_project(ctx.project)
      assert People.link_target(token) == :error
    end

    test "a project link promotes whoever opens it and lands them on the project", ctx do
      People.Store.add_member(ctx.shared.id, ctx.guest.id, "owner")
      assert {:ok, %{url: url}} = People.mint_project_link(ctx.owner, ctx.project.id)
      token = url |> String.split("/j/") |> List.last()
      Ravix.Hub.subscribe(ctx.project.id)

      assert {:ok, "/p/#{ctx.project.id}"} == People.claim_link(ctx.guest.id, token)
      assert People.Store.project_member?(ctx.project.id, ctx.guest.id)
      # The promotion rule holds on this way in too.
      refute People.Store.member?(ctx.shared.id, ctx.guest.id)
      assert_receive {:hub, %Event{name: :people, track_id: nil}}

      # The owner opening their own link writes nothing.
      assert {:ok, _} = People.claim_link(ctx.owner.id, token)
      refute People.Store.project_member?(ctx.project.id, ctx.owner.id)

      # And after the project is archived, nothing.
      archive_project(ctx.project)
      assert :error = People.claim_link(ctx.other.id, token)
      refute People.Store.project_member?(ctx.project.id, ctx.other.id)
    end
  end
end

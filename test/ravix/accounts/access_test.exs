defmodule Ravix.Accounts.AccessTest do
  use Ravix.DataCase, async: true

  alias Ravix.Accounts.Access

  setup do
    owner = insert_user(login: "owner")
    guest = insert_user(login: "guest")
    stranger = insert_user(login: "stranger")
    project = insert_project(user: owner)
    track = insert_track(project: project, created_by_login: "owner")
    other = insert_track(project: project, created_by_login: "guest")

    %{
      owner: owner,
      guest: guest,
      stranger: stranger,
      project: project,
      track: track,
      other: other
    }
  end

  describe "project_of/2" do
    test "the owner, and nobody else, not even a member", ctx do
      insert_project_member(ctx.project, ctx.guest)
      assert {:ok, %{id: id}} = Access.project_of(ctx.owner, ctx.project.id)
      assert id == ctx.project.id
      assert {:error, :not_found} = Access.project_of(ctx.guest, ctx.project.id)
      assert {:error, :not_found} = Access.project_of(ctx.stranger, ctx.project.id)
      assert {:error, :not_found} = Access.project_of(ctx.owner, "nope")
      assert {:error, :not_found} = Access.project_of(ctx.owner, nil)
    end

    test "an archived project is gone for its owner too", ctx do
      archive(ctx.project)
      assert {:error, :not_found} = Access.project_of(ctx.owner, ctx.project.id)
    end
  end

  describe "project_access/2" do
    test "owner as owner, project member as member, track member and stranger not at all",
         ctx do
      insert_project_member(ctx.project, ctx.guest)
      assert {:ok, %{role: :owner}} = Access.project_access(ctx.owner, ctx.project.id)

      assert {:ok, %{role: :member, project: p}} =
               Access.project_access(ctx.guest, ctx.project.id)

      assert p.id == ctx.project.id
      assert {:error, :not_found} = Access.project_access(ctx.stranger, ctx.project.id)

      # An invitation to a branch is not an invitation to the machine.
      insert_track_member(ctx.track, ctx.stranger)
      assert {:error, :not_found} = Access.project_access(ctx.stranger, ctx.project.id)
      assert {:error, :not_found} = Access.project_access(ctx.owner, "nope")
    end

    test "archived is not found for everybody", ctx do
      insert_project_member(ctx.project, ctx.guest)
      archive(ctx.project)
      assert {:error, :not_found} = Access.project_access(ctx.owner, ctx.project.id)
      assert {:error, :not_found} = Access.project_access(ctx.guest, ctx.project.id)
    end
  end

  describe "track_access/2" do
    test "a track member reaches this track and only this track", ctx do
      insert_track_member(ctx.track, ctx.guest)

      assert {:ok, %{role: :member, track: t, project: p}} =
               Access.track_access(ctx.guest, ctx.track.id)

      assert t.id == ctx.track.id
      assert p.id == ctx.project.id
      assert {:error, :not_found} = Access.track_access(ctx.guest, ctx.other.id)
      assert {:error, :not_found} = Access.track_access(ctx.stranger, ctx.track.id)
      assert {:error, :not_found} = Access.track_access(ctx.owner, "nope")
    end

    test "a project member reaches every track, as a member", ctx do
      insert_project_member(ctx.project, ctx.guest)
      assert {:ok, %{role: :member}} = Access.track_access(ctx.guest, ctx.track.id)
      assert {:ok, %{role: :member}} = Access.track_access(ctx.guest, ctx.other.id)
    end

    test "the owner is the owner everywhere, including a closed track", ctx do
      close(ctx.track)
      assert {:ok, %{role: :owner}} = Access.track_access(ctx.owner, ctx.track.id)
      assert {:ok, %{role: :owner}} = Access.track_access(ctx.owner, ctx.other.id)
    end

    test "a closed track stops admitting members of either kind", ctx do
      insert_track_member(ctx.track, ctx.guest)
      insert_project_member(ctx.project, ctx.stranger)
      close(ctx.track)
      assert {:error, :not_found} = Access.track_access(ctx.guest, ctx.track.id)
      assert {:error, :not_found} = Access.track_access(ctx.stranger, ctx.track.id)
    end

    test "an archived project takes its tracks with it", ctx do
      insert_track_member(ctx.track, ctx.guest)
      archive(ctx.project)
      assert {:error, :not_found} = Access.track_access(ctx.owner, ctx.track.id)
      assert {:error, :not_found} = Access.track_access(ctx.guest, ctx.track.id)
    end
  end

  describe "require_owner/2 and require_owner_or_cutter/4" do
    test "owner-only says so in the message", ctx do
      assert :ok = Access.require_owner(:owner, "rebuild it")

      assert {:error, {:forbidden, "Only the owner of this project can rebuild it."}} =
               Access.require_owner(:member, "rebuild it")

      assert :ok = Access.require_owner_or_cutter(:owner, ctx.guest, ctx.track, "close it")
    end

    test "whoever opened the track may too, matched on login regardless of case", ctx do
      cutter = insert_user(login: "GUEST")
      assert :ok = Access.require_owner_or_cutter(:member, cutter, ctx.other, "close it")
      assert :ok = Access.require_owner_or_cutter(:member, ctx.guest, ctx.other, "close it")

      assert {:error,
              {:forbidden,
               "Only the owner of this project, or whoever opened this track, can close it."}} =
               Access.require_owner_or_cutter(:member, ctx.guest, ctx.track, "close it")

      nameless = %{ctx.track | created_by_login: nil}

      assert {:error, {:forbidden, _}} =
               Access.require_owner_or_cutter(:member, ctx.guest, nameless, "close it")
    end
  end

  describe "member?/2 and project_member?/2" do
    test "plain lookups on the two membership tables", ctx do
      refute Access.member?(ctx.track.id, ctx.guest.id)
      refute Access.project_member?(ctx.project.id, ctx.guest.id)
      insert_track_member(ctx.track, ctx.guest)
      insert_project_member(ctx.project, ctx.stranger)
      assert Access.member?(ctx.track.id, ctx.guest.id)
      refute Access.member?(ctx.other.id, ctx.guest.id)
      assert Access.project_member?(ctx.project.id, ctx.stranger.id)
      refute Access.project_member?(ctx.project.id, ctx.guest.id)
    end
  end

  defp archive(project) do
    project
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp close(track) do
    track
    |> Ecto.Changeset.change(closed_at: DateTime.utc_now())
    |> Repo.update!()
  end
end

defmodule Ravix.SchemasTest do
  use Ravix.DataCase, async: true

  alias Ravix.Accounts.{OAuthState, Session, User}
  alias Ravix.Previews.{Preview, PreviewAgentGrant, PreviewDefault, PreviewGrant}
  alias Ravix.Projects.{Project, ProjectInvite, ProjectLink, ProjectMember}
  alias Ravix.PromptQueue.Item
  alias Ravix.Tracks.{Track, TrackInvite, TrackLink, TrackMember, TrackRead}

  # -- accounts -------------------------------------------------------------

  describe "User" do
    test "inserts through the changeset, minting id and timestamps" do
      assert {:ok, user} = User.changeset(%User{}, user_attrs(login: "ana")) |> Repo.insert()
      assert {:ok, _} = Ecto.UUID.cast(user.id)
      assert user.login == "ana"
      assert %DateTime{} = user.created_at
      assert %DateTime{} = user.last_seen_at
    end

    test "requires github_id and login" do
      changeset = User.changeset(%User{}, %{})
      assert %{github_id: ["can't be blank"], login: ["can't be blank"]} = errors_on(changeset)
    end

    test "github_id is unique" do
      insert_user(github_id: "77")

      assert {:error, changeset} =
               User.changeset(%User{}, user_attrs(github_id: "77")) |> Repo.insert()

      assert %{github_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "Session" do
    test "the factory stores only the sha256 of the token it returns" do
      user = insert_user()
      {token, session} = insert_session(user)
      assert session.token_hash == Ravix.Crypto.sha256(token)
      refute session.token_hash == token
      assert session.user_id == user.id
      assert DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt
    end

    test "requires expires_at and a user" do
      changeset = Session.changeset(%Session{}, %{"token_hash" => "h"})
      assert %{user_id: ["can't be blank"], expires_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "is deleted with its user" do
      user = insert_user()
      {_, session} = insert_session(user)
      Repo.delete!(user)
      refute Repo.get(Session, session.token_hash)
    end

    test "token_hash is the primary key" do
      user = insert_user()
      {_, session} = insert_session(user)

      assert {:error, changeset} =
               Session.changeset(
                 %Session{},
                 session_attrs(user: user, token_hash: session.token_hash)
               )
               |> Repo.insert()

      assert %{token_hash: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "OAuthState" do
    test "inserts and is keyed by state" do
      state = insert_oauth_state(kind: "install", redirect: "/p/x")
      assert %OAuthState{kind: "install", redirect: "/p/x"} = Repo.get!(OAuthState, state.state)

      assert {:error, changeset} =
               OAuthState.changeset(%OAuthState{}, %{"state" => state.state, "kind" => "login"})
               |> Repo.insert()

      assert %{state: ["has already been taken"]} = errors_on(changeset)
    end

    test "requires kind" do
      assert %{kind: ["can't be blank"]} =
               errors_on(OAuthState.changeset(%OAuthState{}, %{"state" => "s"}))
    end
  end

  # -- projects -------------------------------------------------------------

  describe "Project" do
    test "inserts through the changeset with defaults" do
      user = insert_user()

      assert {:ok, project} =
               Project.changeset(%Project{}, project_attrs(user: user, name: "Ravix"))
               |> Repo.insert()

      assert project.rev == 1
      assert project.instructions == ""
      assert project.repo_private == false
      assert is_nil(project.archived_at)
      assert project.user_id == user.id
    end

    test "requires the three Fountain ids and the harness" do
      changeset = Project.changeset(%Project{}, %{})
      errors = errors_on(changeset)

      for field <- ~w(user_id name agent_id environment_id runtime model)a do
        assert errors[field] == ["can't be blank"], "#{field} should be required"
      end
    end

    test "rejects a rev below 1" do
      changeset = Project.changeset(%Project{}, project_attrs(user_id: "u", rev: 0))
      assert %{rev: [_]} = errors_on(changeset)
    end

    test "is deleted with its user, and takes its tracks along" do
      project = insert_project()
      track = insert_track(project: project)
      Repo.delete!(Repo.get!(User, project.user_id))
      refute Repo.get(Project, project.id)
      refute Repo.get(Track, track.id)
    end
  end

  describe "ProjectMember" do
    test "is unique per (project, user) and cascades from both sides" do
      project = insert_project()
      member = insert_user()
      insert_project_member(project, member)

      assert {:error, changeset} =
               ProjectMember.changeset(%ProjectMember{}, %{
                 "project_id" => project.id,
                 "user_id" => member.id,
                 "invited_by" => "x"
               })
               |> Repo.insert()

      assert %{project_id: ["has already been taken"]} = errors_on(changeset)

      Repo.delete!(member)
      assert Repo.aggregate(ProjectMember, :count) == 0

      other = insert_user()
      insert_project_member(project, other)
      Repo.delete!(project)
      assert Repo.aggregate(ProjectMember, :count) == 0
    end
  end

  describe "ProjectInvite" do
    test "is keyed on (project, github_id) and cascades with the project" do
      project = insert_project()
      invite = insert_project_invite(project, github_id: "99", login: "ana")

      assert {:error, changeset} =
               ProjectInvite.changeset(%ProjectInvite{}, %{
                 "project_id" => project.id,
                 "github_id" => "99",
                 "login" => "ana-renamed",
                 "invited_by" => "x"
               })
               |> Repo.insert()

      assert %{project_id: ["has already been taken"]} = errors_on(changeset)

      Repo.delete!(project)
      refute Repo.get_by(ProjectInvite, github_id: invite.github_id)
    end
  end

  describe "ProjectLink" do
    test "one per project, hashed, unique hash" do
      project = insert_project()
      {token, link} = insert_project_link(project)
      assert link.token_hash == Ravix.Crypto.sha256(token)

      assert {:error, changeset} =
               ProjectLink.changeset(%ProjectLink{}, %{
                 "project_id" => project.id,
                 "token_hash" => "other",
                 "created_by" => "x",
                 "expires_at" => DateTime.utc_now()
               })
               |> Repo.insert()

      assert %{project_id: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               ProjectLink.changeset(%ProjectLink{}, %{
                 "project_id" => insert_project().id,
                 "token_hash" => link.token_hash,
                 "created_by" => "x",
                 "expires_at" => DateTime.utc_now()
               })
               |> Repo.insert()

      assert %{token_hash: ["has already been taken"]} = errors_on(changeset)

      Repo.delete!(project)
      refute Repo.get(ProjectLink, project.id)
    end
  end

  # -- tracks ---------------------------------------------------------------

  describe "Track" do
    test "inserts through the changeset" do
      project = insert_project()

      attrs =
        track_attrs(project: project, slug: "fix-login", origin_kind: "pr", origin_number: 12)

      assert {:ok, track} = Track.changeset(%Track{}, attrs) |> Repo.insert()
      assert track.slug == "fix-login"
      assert track.origin_number == 12
      assert track.workdir == "/home/sprite/work/fix-login"
      assert String.ends_with?(track.branch, "fix-login-#{track.id}")
      assert track.rev == 1
      assert is_nil(track.opened_at)
      assert is_nil(track.closed_at)
    end

    test "requires slug, title, branch, workdir, origin_kind and the author" do
      errors = errors_on(Track.changeset(%Track{}, %{}))

      for field <- ~w(project_id slug title branch workdir origin_kind created_by_login)a do
        assert errors[field] == ["can't be blank"], "#{field} should be required"
      end
    end

    test "one live track per slug per project" do
      project = insert_project()
      insert_track(project: project, slug: "same")

      assert {:error, changeset} =
               Track.changeset(%Track{}, track_attrs(project: project, slug: "same"))
               |> Repo.insert()

      assert %{slug: ["is already an open track in this project"]} = errors_on(changeset)

      # The same slug on another project is fine.
      assert %Track{} = insert_track(slug: "same")
    end

    test "a closed track frees its slug" do
      project = insert_project()
      insert_track(project: project, slug: "reused", closed_at: DateTime.utc_now())
      assert %Track{} = insert_track(project: project, slug: "reused")
    end

    test "is deleted with its project" do
      track = insert_track()
      Repo.delete!(Repo.get!(Project, track.project_id))
      refute Repo.get(Track, track.id)
    end
  end

  describe "TrackMember" do
    test "is unique per (track, user) and cascades from both sides" do
      track = insert_track()
      member = insert_user()
      insert_track_member(track, member)

      assert {:error, changeset} =
               TrackMember.changeset(%TrackMember{}, %{
                 "track_id" => track.id,
                 "user_id" => member.id,
                 "invited_by" => "x"
               })
               |> Repo.insert()

      assert %{track_id: ["has already been taken"]} = errors_on(changeset)

      Repo.delete!(track)
      assert Repo.aggregate(TrackMember, :count) == 0

      track = insert_track()
      insert_track_member(track, member)
      Repo.delete!(member)
      assert Repo.aggregate(TrackMember, :count) == 0
    end
  end

  describe "TrackInvite" do
    test "is keyed on (track, github_id) and cascades with the track" do
      track = insert_track()
      insert_track_invite(track, github_id: "5")

      assert {:error, changeset} =
               TrackInvite.changeset(%TrackInvite{}, %{
                 "track_id" => track.id,
                 "github_id" => "5",
                 "login" => "x",
                 "invited_by" => "y"
               })
               |> Repo.insert()

      assert %{track_id: ["has already been taken"]} = errors_on(changeset)

      Repo.delete!(track)
      assert Repo.aggregate(TrackInvite, :count) == 0
    end
  end

  describe "TrackLink" do
    test "one per track, hashed, unique hash, cascades" do
      track = insert_track()
      {token, link} = insert_track_link(track)
      assert link.token_hash == Ravix.Crypto.sha256(token)

      assert {:error, changeset} =
               TrackLink.changeset(%TrackLink{}, %{
                 "track_id" => track.id,
                 "token_hash" => "other",
                 "created_by" => "x",
                 "expires_at" => DateTime.utc_now()
               })
               |> Repo.insert()

      assert %{track_id: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               TrackLink.changeset(%TrackLink{}, %{
                 "track_id" => insert_track().id,
                 "token_hash" => link.token_hash,
                 "created_by" => "x",
                 "expires_at" => DateTime.utc_now()
               })
               |> Repo.insert()

      assert %{token_hash: ["has already been taken"]} = errors_on(changeset)

      Repo.delete!(track)
      refute Repo.get(TrackLink, track.id)
    end
  end

  describe "TrackRead" do
    test "one per (track, user), stamped now, cascades" do
      track = insert_track()
      user = insert_user()
      read = insert_track_read(track, user)
      assert %DateTime{} = read.seen_at

      assert {:error, changeset} =
               TrackRead.changeset(%TrackRead{}, %{"track_id" => track.id, "user_id" => user.id})
               |> Repo.insert()

      assert %{track_id: ["has already been taken"]} = errors_on(changeset)

      Repo.delete!(user)
      assert Repo.aggregate(TrackRead, :count) == 0
    end
  end

  # -- prompt queue ---------------------------------------------------------

  describe "PromptQueue.Item" do
    test "inserts with a database-assigned sequence and a queued status" do
      track = insert_track()
      user = insert_user()
      first = insert_prompt(track: track, user: user)
      second = insert_prompt(track: track, user: user)
      assert is_integer(first.sequence)
      assert second.sequence > first.sequence
      assert first.status == :queued
      assert is_nil(first.error)
      assert Jason.decode!(first.payload)["images"] == []
    end

    test "validates the status enum" do
      changeset =
        Item.changeset(%Item{}, prompt_attrs(track_id: "t", user_id: "u", status: "bogus"))

      assert %{status: ["is invalid"]} = errors_on(changeset)

      for status <- ~w(queued sending failed unconfirmed sent cancelled) do
        assert Item.changeset(%Item{}, prompt_attrs(track_id: "t", user_id: "u", status: status)).valid?
      end
    end

    test "requires payload, author and the two parents" do
      errors = errors_on(Item.changeset(%Item{}, %{}))

      for field <- ~w(track_id user_id author_login payload)a do
        assert errors[field] == ["can't be blank"], "#{field} should be required"
      end
    end

    test "id is unique: the receipt for a retried request" do
      prompt = insert_prompt()

      assert {:error, changeset} =
               Item.changeset(
                 %Item{},
                 prompt_attrs(track_id: prompt.track_id, user_id: prompt.user_id, id: prompt.id)
               )
               |> Repo.insert()

      assert %{id: ["has already been taken"]} = errors_on(changeset)
    end

    test "is deleted with its track and with its user" do
      prompt = insert_prompt()
      Repo.delete!(Repo.get!(Track, prompt.track_id))
      refute Repo.get_by(Item, id: prompt.id)

      prompt = insert_prompt()
      Repo.delete!(Repo.get!(User, prompt.user_id))
      refute Repo.get_by(Item, id: prompt.id)
    end
  end

  # -- previews -------------------------------------------------------------

  describe "Preview" do
    test "inserts the stopped row the store writes on ensure" do
      track = insert_track()
      preview = insert_preview(track: track)
      assert String.starts_with?(preview.hostname, "t-")
      assert preview.row["state"] == "stopped"
      assert preview.row["service"] == "sy-#{preview.hostname}"
      assert %Preview{row: %{"desired" => "stopped"}} = Repo.get!(Preview, track.id)
    end

    test "hostname is unique" do
      preview = insert_preview()

      assert {:error, changeset} =
               Preview.changeset(
                 %Preview{},
                 preview_attrs(track: insert_track(), hostname: preview.hostname)
               )
               |> Repo.insert()

      assert %{hostname: ["has already been taken"]} = errors_on(changeset)
    end

    test "one preview per track" do
      preview = insert_preview()

      assert {:error, changeset} =
               Preview.changeset(%Preview{}, preview_attrs(track_id: preview.track_id))
               |> Repo.insert()

      assert %{track_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "a port is held once per sprite, and only once the sprite is set" do
      insert_preview(sprite: "sprite-a", port: 20_000)

      assert {:error, changeset} =
               Preview.changeset(
                 %Preview{},
                 preview_attrs(track: insert_track(), sprite: "sprite-a", port: 20_000)
               )
               |> Repo.insert()

      assert %{port: ["is already taken on this sprite"]} = errors_on(changeset)

      # Same port on another sprite, and unallocated rows, are fine.
      assert %Preview{} = insert_preview(sprite: "sprite-b", port: 20_000)
      assert %Preview{} = insert_preview(sprite: nil, port: 20_000)
      assert %Preview{} = insert_preview(sprite: nil, port: 20_000)
    end

    test "the track reference has no cascade: a track with a preview is closed, not deleted" do
      preview = insert_preview()

      assert_raise Ecto.ConstraintError, ~r/previews_track_id_fkey/, fn ->
        Repo.delete!(Repo.get!(Track, preview.track_id))
      end
    end
  end

  describe "PreviewDefault" do
    test "one per project, holding the config as a map" do
      project = insert_project()

      insert_preview_default(project,
        config: %{"directory" => "web", "command" => "bun dev", "readinessPath" => "/"}
      )

      assert %PreviewDefault{config: %{"command" => "bun dev"}} =
               Repo.get!(PreviewDefault, project.id)

      assert {:error, changeset} =
               PreviewDefault.changeset(%PreviewDefault{}, %{
                 "project_id" => project.id,
                 "config" => %{}
               })
               |> Repo.insert()

      assert %{project_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "PreviewGrant" do
    test "is keyed by hash, typed by kind, and goes with the session" do
      user = insert_user()
      {_, session} = insert_session(user)
      track = insert_track()
      grant = insert_preview_grant(track, session, kind: "ticket")
      assert grant.kind == :ticket
      assert is_integer(grant.expires)

      assert %{kind: ["is invalid"]} =
               errors_on(
                 PreviewGrant.changeset(%PreviewGrant{}, %{
                   "hash" => "h",
                   "track_id" => track.id,
                   "session_hash" => session.token_hash,
                   "expires" => 1,
                   "kind" => "forever"
                 })
               )

      Repo.delete!(session)
      refute Repo.get(PreviewGrant, grant.hash)
    end
  end

  describe "PreviewAgentGrant" do
    test "one per track, whole grant in the row" do
      track = insert_track()
      user = insert_user()
      grant = insert_preview_agent_grant(track, user)
      assert grant.row["trackId"] == track.id
      assert grant.row["hash"] == grant.hash

      assert {:error, changeset} =
               PreviewAgentGrant.changeset(%PreviewAgentGrant{}, %{
                 "hash" => "another",
                 "track_id" => track.id,
                 "user_id" => user.id,
                 "expires" => 1,
                 "row" => %{}
               })
               |> Repo.insert()

      assert %{track_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  # -- factory --------------------------------------------------------------

  describe "factory" do
    test "attrs helpers return string-keyed maps that pass their changesets" do
      user = insert_user()
      project = insert_project(user: user)
      track = insert_track(project: project)

      for attrs <- [
            user_attrs(),
            session_attrs(user: user),
            project_attrs(user: user),
            track_attrs(project: project),
            prompt_attrs(track: track, user: user),
            preview_attrs(track: track)
          ] do
        assert Enum.all?(Map.keys(attrs), &is_binary/1)
      end

      assert User.changeset(%User{}, user_attrs()).valid?
      assert Session.changeset(%Session{}, session_attrs(user: user)).valid?
      assert Project.changeset(%Project{}, project_attrs(user: user)).valid?
      assert Track.changeset(%Track{}, track_attrs(project: project)).valid?
      assert Item.changeset(%Item{}, prompt_attrs(track: track, user: user)).valid?
      assert Preview.changeset(%Preview{}, preview_attrs(track: track)).valid?
    end

    test "accepts keyword lists and maps with atom or string keys" do
      assert %User{login: "kw"} = insert_user(login: "kw")
      assert %User{login: "atom"} = insert_user(%{login: "atom"})
      assert %User{login: "str"} = insert_user(%{"login" => "str"})
    end

    test "fills in parents so a bare call is a whole graph" do
      prompt = insert_prompt()
      track = Repo.get!(Track, prompt.track_id) |> Repo.preload(project: :user)
      assert track.project.user.id == prompt.user_id

      preview = insert_preview()
      assert Repo.get!(Track, preview.track_id)
    end

    test "given ids win over invented parents" do
      user = insert_user()
      project = insert_project(user_id: user.id)
      assert project.user_id == user.id
      track = insert_track(project_id: project.id, id: "fixed-id")
      assert track.id == "fixed-id"
      assert String.ends_with?(track.branch, "-fixed-id")
    end
  end
end

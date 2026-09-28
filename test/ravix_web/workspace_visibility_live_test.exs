defmodule RavixWeb.WorkspaceVisibilityLiveTest do
  @moduledoc """
  ADR 0009 phase 3b through the pages: a private sibling's name and count
  stay out of a workspace member's rail, search, badges and Inbox; URL
  params for tracks they may not see, or another tenant's, land nowhere;
  and a removal reaches an open track page with or without its notice.

  The switch is stubbed (`Ravix.Config` is Mimic-copied), which reaches the
  pages through `$callers`, so this file stays async. Provider-backed reads
  on the track page are stubbed as `RavixWeb.TrackLiveTest` stubs them;
  access itself is never stubbed.
  """
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  import Ecto.Query, only: [where: 2]

  alias Ravix.Projects.Project
  alias Ravix.Repo
  alias Ravix.Tracks
  alias Ravix.Tracks.{Track, Transcript}
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Membership, Store}

  setup do
    stub(Ravix.Config, :workspace_access?, fn -> true end)

    owner = insert_user(login: "wsowner")
    colleague = insert_user(login: "wscolleague")
    creator = insert_user(login: "wscreator")
    stranger = insert_user(login: "wsstranger")
    {:ok, workspace} = Store.ensure_personal_workspace(owner)
    for user <- [colleague, creator], do: member!(workspace, user)

    project = in_workspace(insert_project(user: owner, name: "Team repo"), workspace)

    # Both need attention (a failed setup), so each counts on any badge
    # that is allowed to count it.
    open =
      insert_track(
        project: project,
        title: "Open work",
        setup_state: "failed",
        created_by: owner.id,
        created_by_login: owner.login
      )

    secret =
      insert_track(
        project: project,
        title: "Private investigation",
        visibility: :private,
        sandbox_layout: :dedicated,
        setup_state: "failed",
        created_by: creator.id,
        created_by_login: creator.login
      )

    {:ok, elsewhere} = Store.ensure_personal_workspace(stranger)
    theirs = in_workspace(insert_project(user: stranger, name: "Their repo"), elsewhere)
    their_track = insert_track(project: theirs, title: "Their work", created_by: stranger.id)

    %{
      owner: owner,
      colleague: colleague,
      creator: creator,
      workspace: workspace,
      project: project,
      open: open,
      secret: secret,
      theirs: theirs,
      their_track: their_track
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

  defp open_page(user, path) do
    {:ok, view, _} = live(log_in_user(build_conn(), user), path)
    render_async(view, 5_000)
    view
  end

  defp search(view, q) do
    render_click(view, "dialog", %{name: "search"})
    view |> form("#search-form", q: q) |> render_change()
  end

  describe "discovery" do
    test "a workspace member's rail, search and badge leave out a private sibling", ctx do
      view = open_page(ctx.colleague, "/p/#{ctx.project.id}")

      assert has_element?(view, "#project-track-tab-#{ctx.open.id}")
      refute has_element?(view, "#project-track-tab-#{ctx.secret.id}")
      refute render(view) =~ "Private investigation"
      assert has_element?(view, "#project-link-#{ctx.project.id} .badge[aria-label='1 unread']")

      search(view, "investigation")
      refute has_element?(view, "#search-track-link-#{ctx.secret.id}")
      search(view, "work")
      assert has_element?(view, "#search-track-link-#{ctx.open.id}")
      refute render(view) =~ "Private investigation"
    end

    test "its creator sees and counts it, in the same places", ctx do
      view = open_page(ctx.creator, "/p/#{ctx.project.id}")

      assert has_element?(view, "#project-track-tab-#{ctx.secret.id}")
      assert has_element?(view, "#project-link-#{ctx.project.id} .badge[aria-label='2 unread']")
      search(view, "investigation")
      assert has_element?(view, "#search-track-link-#{ctx.secret.id}")
    end

    test "the Inbox lists only what the viewer may see", ctx do
      colleague = open_page(ctx.colleague, "/inbox")
      assert render(colleague) =~ "Open work"
      refute render(colleague) =~ "Private investigation"

      creator = open_page(ctx.creator, "/inbox")
      assert render(creator) =~ "Private investigation"
    end

    test "with the switch off, a workspace member sees none of it", ctx do
      stub(Ravix.Config, :workspace_access?, fn -> false end)
      view = open_page(ctx.colleague, "/")

      refute has_element?(view, "#project-link-#{ctx.project.id}")
      refute render(view) =~ "Open work"
      refute render(view) =~ "Private investigation"
    end
  end

  describe "URL params" do
    test "a private sibling's URL, and another tenant's, open no track", ctx do
      for {project, track} <- [
            {ctx.project, ctx.secret},
            {ctx.theirs, ctx.their_track}
          ] do
        conn = log_in_user(build_conn(), ctx.colleague)

        html =
          case live(conn, "/p/#{project.id}/t/#{track.id}") do
            {:ok, view, _} ->
              render_async(view, 5_000)
              refute find_live_child(view, "track-host")
              render(view)

            {:error, {_kind, %{to: to}}} ->
              refute to =~ track.id
              ""
          end

        refute html =~ track.title
      end
    end
  end

  describe "an open track page" do
    setup ctx do
      stub(Tracks, :get, fn _, id, _opts ->
        row = Repo.get!(Track, id)

        {:ok,
         %{
           track: Tracks.present(row, role: :member),
           header: %Tracks.Header{
             copy_of: nil,
             branched_from: nil,
             created: %{dir: row.slug, files: nil},
             has_setup_script: false
           },
           threads: [],
           starters: [],
           models: []
         }}
      end)

      stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.empty("claude")} end)
      stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
      stub(Tracks, :beat, fn _, _, _ -> :ok end)
      stub(Tracks, :mark_read, fn _, _, _ -> :ok end)

      {:ok, parent, _} =
        live(
          log_in_user(build_conn(), ctx.colleague),
          "/p/#{ctx.project.id}/t/#{ctx.open.id}"
        )

      view = find_live_child(parent, "track-host")
      render_async(view, 5_000)
      %{view: view}
    end

    test "is left on the removal notice", ctx do
      ref = Process.monitor(ctx.view.pid)
      :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.colleague.id)
      assert_receive {:DOWN, ^ref, :process, _, {:shutdown, {:redirect, %{to: "/"}}}}, 2_000
    end

    test "is left on its next event when the notice was lost", ctx do
      {:ok, _} = Store.revoke_membership(ctx.workspace.id, ctx.colleague.id, ctx.owner.id)

      :sys.replace_state(ctx.view.pid, fn state ->
        update_in(state.socket.assigns.track_guard, &%{&1 | stale?: true})
      end)

      assert {:error, {:redirect, %{to: "/"}}} =
               render_click(ctx.view, "select-thread", %{"thread_id" => ctx.open.id})
    end
  end
end

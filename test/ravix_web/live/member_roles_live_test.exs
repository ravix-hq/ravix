defmodule RavixWeb.Live.MemberRolesLiveTest do
  @moduledoc """
  ADR 0010 on the page: a read-only member's composer is disabled, a forged
  event is refused by the context behind it, a change of role reaches a page
  that is already open, and the people dialog offers the role menu and a
  copy link.
  """
  use RavixWeb.ConnCase, async: true

  import Mimic
  import Phoenix.LiveViewTest

  alias Ravix.Accounts.Access
  alias Ravix.{People, PromptQueue, Repo, Tracks}
  alias Ravix.Tracks.{Track, Transcript}

  setup %{conn: conn} do
    owner = insert_user(login: "owner")
    reader = insert_user(login: "reader")
    writer = insert_user(login: "writer")
    project = insert_project(user: owner)

    track =
      insert_track(
        project: project,
        conversation_id: "live-conversation",
        created_by_login: owner.login
      )

    insert_track_member(track, reader, role: :read)
    insert_track_member(track, writer, role: :write)

    # The page's detail is the real door's answer, so a role change is
    # visible to it the way `Ravix.Tracks.get/3` would make it visible.
    stub(Tracks, :get, fn user, id, _opts ->
      with {:ok, access} <- Access.track_access(user, id) do
        row = Repo.get!(Track, id)

        {:ok,
         %{
           track: Tracks.present(row, role: access.role, level: access.level),
           header: %Ravix.Tracks.Header{
             copy_of: nil,
             branched_from: nil,
             created: %{dir: "t", files: nil},
             has_setup_script: false
           },
           threads: [],
           starters: [],
           models: []
         }}
      end
    end)

    stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _ -> :ok end)

    %{conn: conn, owner: owner, reader: reader, writer: writer, project: project, track: track}
  end

  defp track_page(ctx, user) do
    {:ok, parent, _} =
      live(log_in_user(ctx.conn, user), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    render_async(view, 5_000)
    {view, parent}
  end

  defp open_people(view) do
    render_click(view, "dialog", %{name: "people"})
    view
  end

  describe "a read-only member's page" do
    test "shows the composer disabled for prompts, and comments stay open", ctx do
      {view, _} = track_page(ctx, ctx.reader)

      assert has_element?(view, "#composer-read-only", "You have Read access")
      assert has_element?(view, "#composer-#{ctx.track.id}[disabled]")
      assert has_element?(view, "#composer-form button[type=submit][disabled]")

      render_click(view, "composer-mode", %{"mode" => "comment"})
      refute has_element?(view, "#composer-read-only")
      refute has_element?(view, "#composer-#{ctx.track.id}[disabled]")
    end

    test "a forged send is refused, and nothing is queued", ctx do
      {view, _} = track_page(ctx, ctx.reader)

      html = render_submit(view, "send", %{"text" => "let me in"})
      assert html =~ "Your role on this track is Read."
      assert PromptQueue.Store.queued_prompts() == []
    end

    test "forged setting changes are refused by the context", ctx do
      {view, parent} = track_page(ctx, ctx.reader)

      render_submit(view, "rename", %{"rename_track" => %{"title" => "Mine now"}})
      assert Repo.get!(Track, ctx.track.id).title == ctx.track.title

      render_click(view, "set-model", %{"model" => "other"})
      render_async(view)
      assert render(parent) =~ "Your role on this track is Read."
    end

    test "a writer's page is not read-only", ctx do
      {view, _} = track_page(ctx, ctx.writer)
      refute has_element?(view, "#composer-read-only")
      refute has_element?(view, "#composer-#{ctx.track.id}[disabled]")
    end
  end

  describe "a live session" do
    test "hears its role drop to read, and back", ctx do
      {view, _} = track_page(ctx, ctx.writer)
      refute has_element?(view, "#composer-read-only")

      assert {:ok, _} = People.set_role(ctx.owner, ctx.track.id, "writer", "read")
      render_async(view, 5_000)
      assert has_element?(view, "#composer-read-only")

      assert {:ok, _} = People.set_role(ctx.owner, ctx.track.id, "writer", "write")
      render_async(view, 5_000)
      refute has_element?(view, "#composer-read-only")
    end

    test "is sent away when the member is removed", ctx do
      {view, parent} = track_page(ctx, ctx.writer)
      Process.unlink(parent.pid)
      ref = Process.monitor(view.pid)

      assert {:ok, _} = People.remove(ctx.owner, ctx.track.id, "writer")
      assert_receive {:DOWN, ^ref, _, _, _}, 5_000
    end
  end

  describe "the people dialog" do
    test "an admin changes a role from the menu beside the person", ctx do
      {view, _} = track_page(ctx, ctx.owner)
      open_people(view)

      assert has_element?(view, "#track-people-role-reader", "Read")
      assert has_element?(view, "#track-people-role-menu-reader [role=menuitemradio]", "Admin")

      assert has_element?(
               view,
               "#track-people-role-menu-reader [aria-checked=true]",
               "Read"
             )

      view
      |> element("#track-people-role-menu-reader [phx-value-role=write]")
      |> render_click()

      assert {:ok, %{level: :write}} = Access.track_access(ctx.reader, ctx.track.id)
      assert has_element?(view, "#track-people-role-reader", "Write")

      view
      |> element("#track-people-role-menu-reader button", "Remove access")
      |> render_click()

      assert {:error, :not_found} = Access.track_access(ctx.reader, ctx.track.id)
    end

    test "a non-admin sees roles, no menu, and a forged role change is refused", ctx do
      {view, parent} = track_page(ctx, ctx.writer)
      open_people(view)

      assert has_element?(view, ".people-row .role-label", "Read")
      refute has_element?(view, "[id^=track-people-role-menu-]")
      refute has_element?(view, "#track-people-invite-form")

      view
      |> with_target("#track-people")
      |> render_click("set-role", %{"login" => "reader", "role" => "admin"})

      assert render(parent) =~ "Only an admin can do that."
      assert {:ok, %{level: :read}} = Access.track_access(ctx.reader, ctx.track.id)
    end

    test "everybody gets the track's own link to copy, which is not an invitation", ctx do
      {view, _} = track_page(ctx, ctx.reader)
      open_people(view)

      assert has_element?(
               view,
               "#track-people-copy-link code",
               "/p/#{ctx.project.id}/t/#{ctx.track.id}"
             )

      assert has_element?(view, "#track-people-copy-link button", "Copy link")
      assert render(view) =~ "It does not invite anyone."
      refute render(view) =~ "/j/"
    end

    test "the project's dialog manages project roles", ctx do
      member = insert_user(login: "member")
      insert_project_member(ctx.project, member)

      {:ok, view, _} = live(log_in_user(ctx.conn, ctx.owner), "/p/#{ctx.project.id}")
      open_people(view)
      assert has_element?(view, "#people-role-member", "Write")
      assert has_element?(view, "#people-copy-link code", "/p/#{ctx.project.id}")

      view |> element("#people-role-menu-member [phx-value-role=read]") |> render_click()
      assert {:ok, %{level: :read}} = Access.project_access(member, ctx.project.id)
      assert has_element?(view, "#people-role-member", "Read")
    end
  end
end

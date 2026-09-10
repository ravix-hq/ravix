defmodule RavixWeb.Live.PeopleDialogTest do
  @moduledoc """
  One dialog now serves both units of sharing, so the things that must stay
  *different* between them are worth asserting in one place: what each grants,
  what leaving each does to the page you are on, and who is offered the
  controls at all.
  """
  use RavixWeb.ConnCase, async: false

  import Mimic
  import Phoenix.LiveViewTest

  alias Ravix.Accounts.Access
  alias Ravix.Repo
  alias Ravix.Tracks
  alias Ravix.Tracks.{Track, Transcript}

  setup %{conn: conn} do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)

    # The track page needs a machine to render at all; the dialog under test
    # does not care which, so the provider is stubbed and the rows are real.
    stub(Tracks, :get, fn _user, id ->
      row = Repo.get!(Track, id)
      {:ok, %{track: Tracks.present(row, role: :owner), header: %{}, starters: []}}
    end)

    stub(Tracks, :events, fn _, _ -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _ -> :ok end)

    %{conn: conn, owner: owner, project: project, track: track}
  end

  defp open_people(view) do
    render_click(view, "dialog", %{name: "people"})
    view
  end

  # The track page is a LiveView nested inside the workspace, so its dialog is
  # opened on the child rather than on the page that routed to it.
  defp track_page(conn, user, project, track) do
    {view, _parent} = track_page_with_parent(conn, user, project, track)
    view
  end

  # A child LiveView's `push_navigate/2` moves the whole page, so the redirect
  # is asserted on the root rather than on the track.
  defp track_page_with_parent(conn, user, project, track) do
    {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    view = find_live_child(parent, "track-#{track.id}")
    render_async(view)
    {view, parent}
  end

  describe "the track's dialog and the project's differ where they should" do
    test "each says what it grants, and only the project's mentions the machine", ctx do
      {:ok, project_view, _} = live(log_in_user(ctx.conn, ctx.owner), "/p/#{ctx.project.id}")
      project_html = project_view |> open_people() |> render()

      assert project_html =~ "Project people"
      assert project_html =~ "every track on this machine"

      track_html =
        ctx.conn |> track_page(ctx.owner, ctx.project, ctx.track) |> open_people() |> render()

      assert track_html =~ "Track people"
      refute track_html =~ "every track on this machine"
    end

    test "leaving is worded for what you are leaving", ctx do
      member = insert_user()
      insert_project_member(ctx.project, member)

      {:ok, view, _} = live(log_in_user(ctx.conn, member), "/p/#{ctx.project.id}")
      assert view |> open_people() |> render() =~ "Leave project"

      other = insert_user()
      track = insert_track(project: ctx.project)
      insert_track_member(track, other)

      html = ctx.conn |> track_page(other, ctx.project, track) |> open_people() |> render()
      assert html =~ "Leave"
      refute html =~ "Leave project"
    end
  end

  describe "who is offered the controls" do
    test "the owner may invite and mint a link", ctx do
      {:ok, view, _} = live(log_in_user(ctx.conn, ctx.owner), "/p/#{ctx.project.id}")
      html = view |> open_people() |> render()

      assert html =~ "GitHub username"
      assert html =~ "Create invite link"
    end

    test "a member may leave and nothing else", ctx do
      member = insert_user()
      insert_project_member(ctx.project, member)

      {:ok, view, _} = live(log_in_user(ctx.conn, member), "/p/#{ctx.project.id}")
      html = view |> open_people() |> render()

      refute html =~ "GitHub username"
      refute html =~ "Create invite link"
      assert html =~ "Leave project"
      # And not a control for taking anybody else off.
      refute html =~ "phx-value-login=\"#{ctx.owner.login}\""
    end
  end

  describe "a refusal from the context reaches the page as a sentence" do
    test "inviting somebody who is not on GitHub says so rather than failing quietly", ctx do
      {:ok, view, _} = live(log_in_user(ctx.conn, ctx.owner), "/p/#{ctx.project.id}")
      view = open_people(view)

      html =
        view
        |> element("#people-invite-form")
        |> render_submit(%{"login" => "nobody-here-by-that-name"})

      # The dialog is a component; its refusals still land in the page's flash.
      assert html =~ "GitHub" or html =~ "No such"
      assert has_element?(view, "#people-dialog")
    end
  end

  describe "leaving moves you, and only where each page decides" do
    test "leaving a track you are only a member of returns you to the workspace", ctx do
      member = insert_user()
      insert_track_member(ctx.track, member)

      {view, parent} = track_page_with_parent(ctx.conn, member, ctx.project, ctx.track)

      view
      |> open_people()
      |> element("button[phx-value-login='#{member.login}']")
      |> render_click()

      assert_redirect(parent, "/")
      refute Access.member?(ctx.track.id, member.id)
    end

    test "the owner taking somebody off a track stays on the track", ctx do
      member = insert_user()
      insert_track_member(ctx.track, member)

      view = track_page(ctx.conn, ctx.owner, ctx.project, ctx.track)

      view
      |> open_people()
      |> element("button[phx-value-login='#{member.login}']")
      |> render_click()

      refute Access.member?(ctx.track.id, member.id)
      assert has_element?(view, "#track-people-dialog")
      refute render(view) =~ "@#{member.login}"
    end
  end
end

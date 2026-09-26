defmodule RavixWeb.Live.PeopleDialogTest do
  @moduledoc """
  One dialog now serves both units of sharing, so the things that must stay
  *different* between them are worth asserting in one place: what each grants,
  what leaving each does to the page you are on, and who is offered the
  controls at all.
  """
  use RavixWeb.ConnCase, async: true

  import Mimic
  import Phoenix.LiveViewTest

  alias Ravix.Accounts.Access
  alias Ravix.{People, Projects, Repo, Tracks}
  alias Ravix.Tracks.{Track, Transcript}

  setup %{conn: conn} do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)

    # The track page needs a machine to render at all; the dialog under test
    # does not care which, so the provider is stubbed and the rows are real.
    stub(Tracks, :get, fn _user, id, _opts ->
      row = Repo.get!(Track, id)

      {:ok,
       %{
         track: Tracks.present(row, role: :owner),
         header: blank_header(),
         threads: [],
         starters: [],
         models: []
       }}
    end)

    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _thread_opts -> :ok end)

    %{conn: conn, owner: owner, project: project, track: track}
  end

  test "track headers and people labels are relative to each viewer", ctx do
    member = insert_user()
    guest = insert_user()
    insert_project_member(ctx.project, member)
    insert_track_member(ctx.track, guest)

    for user <- [ctx.owner, member, guest] do
      label =
        if user == ctx.owner,
          do: ctx.project.name,
          else: "#{ctx.owner.login} / #{ctx.project.name}"

      view = track_page(ctx.conn, user, ctx.project, ctx.track)
      assert has_element?(view, ".project-crumb .project-label", label)
      assert has_element?(view, ".project-crumb .dim") == (user != ctx.owner)
      open_people(view)
      assert has_element?(view, "#track-people-dialog .project-label", label)
    end
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
    view = find_live_child(parent, "track-host")
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

  describe "the list says how each person got there" do
    test "a project member on a track's dialog is marked, and cannot be removed there", ctx do
      wide = insert_user()
      insert_project_member(ctx.project, wide)

      html =
        ctx.conn |> track_page(ctx.owner, ctx.project, ctx.track) |> open_people() |> render()

      assert html =~ "@#{wide.login}"
      assert html =~ "in the whole project"

      # `Ravix.People.remove/3` refuses this with "…is in this whole project,
      # not just this track". A button whose only outcome is that sentence is
      # worse than no button: the badge says the same thing without a click.
      refute html =~ ~s(phx-value-login="#{wide.login}")
    end

    test "somebody named on the track itself is not marked, and can be removed", ctx do
      narrow = insert_user()
      insert_track_member(ctx.track, narrow)

      html =
        ctx.conn |> track_page(ctx.owner, ctx.project, ctx.track) |> open_people() |> render()

      assert html =~ ~s(phx-value-login="#{narrow.login}")
      refute html =~ "in the whole project"
    end

    test "the owner is named as such and is offered nothing", ctx do
      html =
        ctx.conn |> track_page(ctx.owner, ctx.project, ctx.track) |> open_people() |> render()

      assert html =~ "@#{ctx.owner.login}"
      assert html =~ "owner"

      # Leaving is not something the owner of the project can do to their own
      # track. The control used to be offered and silently did nothing.
      refute html =~ ~s(phx-value-login="#{ctx.owner.login}")
    end

    test "an invitation nobody has taken up says so", ctx do
      insert_track_invite(ctx.track, github_id: "9001", login: "dana")

      html =
        ctx.conn |> track_page(ctx.owner, ctx.project, ctx.track) |> open_people() |> render()

      assert html =~ "@dana"
      assert html =~ "invited, not signed in yet"
      # Withdrawing an invitation is still the owner's to do.
      assert html =~ ~s(phx-value-login="dana")
    end

    test "the project's own dialog does not label its own members", ctx do
      member = insert_user()
      insert_project_member(ctx.project, member)

      {:ok, view, _} = live(log_in_user(ctx.conn, ctx.owner), "/p/#{ctx.project.id}")
      html = view |> open_people() |> render()

      assert html =~ "@#{member.login}"
      # Here "in the whole project" is what the dialog is about, so saying it
      # per row is noise.
      refute html =~ "in the whole project"
      assert html =~ ~s(phx-value-login="#{member.login}")
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

      view
      |> element("#people-invite-form")
      |> render_submit(%{"login" => "nobody-here-by-that-name"})

      # Inviting asks GitHub and runs off the page, and the component hands
      # the sentence to the page, which puts it in the flash on its next
      # message, so the page is re-read rather than the submit's own return
      # being inspected.
      render_async(view)
      html = render(view)

      # A `live_component` cannot put a flash in the page's own socket -- it
      # has to hand the sentence to the parent. This assertion used to be
      # `html =~ "GitHub" or html =~ "No such"`, which passed on the form's
      # own "GitHub username" label while the refusal was in fact being
      # dropped on the floor. Assert the sentence itself.
      # This deployment has no GitHub App, so that is the refusal. Whichever
      # it is, the point is that a sentence arrives at all.
      assert html =~ RavixWeb.Error.from({:unconfigured, :github}).message
      assert has_element?(view, "#people-dialog")
    end
  end

  describe "inviting somebody asks GitHub off the page" do
    test "the button is disabled until GitHub answers, and the page still answers", ctx do
      {:ok, view, _} = live(log_in_user(ctx.conn, ctx.owner), "/p/#{ctx.project.id}")
      view = open_people(view)
      parent = self()

      stub(People, :add_project, fn user, id, "dana" ->
        send(parent, {:adding, self()})

        receive do
          :finish -> People.list_project(user, id)
        after
          2_000 -> flunk("the invite was never released")
        end
      end)

      view |> element("#people-invite-form") |> render_submit(%{"login" => "dana"})

      assert_receive {:adding, adding}
      assert has_element?(view, "#people-invite-form button[disabled]")
      assert render(view) =~ "Project people"

      send(adding, :finish)
      render_async(view)
      refute has_element?(view, "#people-invite-form button[disabled]")
    end

    @tag capture_log: true
    test "an invite that crashes re-enables the button and says so", ctx do
      {:ok, view, _} = live(log_in_user(ctx.conn, ctx.owner), "/p/#{ctx.project.id}")
      view = open_people(view)
      stub(People, :add_project, fn _, _, _ -> raise "GitHub fell over" end)

      view |> element("#people-invite-form") |> render_submit(%{"login" => "dana"})

      render_async(view)
      assert render(view) =~ "The operation could not finish"
      refute has_element?(view, "#people-invite-form button[disabled]")
    end
  end

  describe "a session that went without notice" do
    # The dialog is a `live_component`, and the page's session hooks never
    # see a component's events; see `RavixWeb.Live.Hooks`.
    setup ctx do
      {token, session} = insert_session(ctx.owner)
      conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
      {:ok, view, _} = live(conn, "/p/#{ctx.project.id}")
      open_people(view)
      %{view: view, session: session}
    end

    test "cannot invite through the dialog", ctx do
      reject(&People.add_project/3)
      Repo.delete!(ctx.session)

      assert {:error, {:redirect, %{to: "/login"}}} =
               ctx.view |> element("#people-invite-form") |> render_submit(%{"login" => "dana"})
    end

    test "cannot remove somebody through the dialog", ctx do
      member = insert_user()
      insert_project_member(ctx.project, member)
      # Re-opened so the list holds the new member; the setup's dialog was
      # read before they were added.
      render_click(ctx.view, "dismiss")
      open_people(ctx.view)
      assert has_element?(ctx.view, "button[phx-value-login='#{member.login}']")

      Repo.delete!(ctx.session)

      assert {:error, {:redirect, %{to: "/login"}}} =
               ctx.view |> element("button[phx-value-login='#{member.login}']") |> render_click()

      assert {:ok, _project} = Projects.get(member, ctx.project.id)
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

  # The ribbon a track with no repository and no setup script gets. A real
  # `Ravix.Tracks.Header` rather than `%{}`: the template reads a field off
  # it, and a stub that answers with an empty map is how a page renders
  # in a test and raises in production.
  defp blank_header,
    do: %Ravix.Tracks.Header{
      copy_of: nil,
      branched_from: nil,
      created: %{dir: "t", files: nil},
      has_setup_script: false
    }
end

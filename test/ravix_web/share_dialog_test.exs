defmodule RavixWeb.ShareDialogTest do
  @moduledoc """
  ADR 0009 phase 5 through the pages: the track header's Share dialog
  (visibility, the @-mention list over workspace members, copy link), the
  cutover's Inbox note, and an open track page losing a private track when
  its permission row or workspace membership goes -- on the notice, and
  when a delayed async result is all that is left to render.

  The switch is stubbed (`Ravix.Config` is Mimic-copied), which reaches the
  pages through `$callers`, so this file stays async. Provider-backed reads
  on the track page are stubbed as `RavixWeb.WorkspaceVisibilityLiveTest`
  stubs them; access itself is never stubbed.
  """
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  import Ecto.Query, only: [where: 2]

  alias Ravix.People
  alias Ravix.People.Cutover
  alias Ravix.Projects.Project
  alias Ravix.Repo
  alias Ravix.Tracks
  alias Ravix.Tracks.{Track, TrackPermission, Transcript}
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Membership, Store}

  setup do
    stub(Ravix.Config, :workspace_access?, fn -> true end)

    owner = insert_user(login: "shareowner")
    creator = insert_user(login: "sharecreator")
    holder = insert_user(login: "shareholder", name: "Holly Holder")
    colleague = insert_user(login: "sharecolleague")
    outsider = insert_user(login: "shareoutsider")
    {:ok, workspace} = Store.create_team_workspace(owner.id, "Team")
    for user <- [creator, holder, colleague], do: member!(workspace, user)

    project = in_workspace(insert_project(user: owner, name: "Team repo"), workspace)

    secret =
      insert_track(
        project: project,
        title: "Private investigation",
        visibility: :private,
        sandbox_layout: :dedicated,
        created_by: creator.id,
        created_by_login: creator.login
      )

    stub_track_page()

    %{
      owner: owner,
      creator: creator,
      holder: holder,
      colleague: colleague,
      outsider: outsider,
      workspace: workspace,
      project: project,
      secret: secret
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

  defp stub_track_page do
    stub(Tracks, :get, fn user, id, _opts -> present(user, id) end)
    stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _ -> :ok end)
  end

  defp present(user, id) do
    row = Repo.get!(Track, id)
    role = if Repo.get!(Project, row.project_id).user_id == user.id, do: :owner, else: :member

    {:ok,
     %{
       track: Tracks.present(row, role: role),
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
  end

  defp track_page(user, track) do
    {:ok, parent, _} =
      live(log_in_user(build_conn(), user), "/p/#{track.project_id}/t/#{track.id}")

    view = find_live_child(parent, "track-host")
    render_async(view, 5_000)
    view
  end

  defp open_share(view) do
    render_click(view, "dialog", %{"name" => "people"})
    view
  end

  describe "the Share dialog" do
    test "says where each person's access to the track comes from (RAV-75)", ctx do
      open =
        insert_track(
          project: ctx.project,
          title: "Open work",
          created_by: ctx.owner.id,
          created_by_login: ctx.owner.login
        )

      insert_project_member(ctx.project, ctx.creator, role: :write)
      insert_track_member(open, ctx.holder, role: :read)
      view = ctx.owner |> track_page(open) |> open_share()

      assert has_element?(view, "#share-access-shareowner", "Admin")
      assert has_element?(view, "#share-access-shareowner .people-source", "owner")
      assert has_element?(view, "#share-access-sharecreator", "Write")
      assert has_element?(view, "#share-access-sharecreator .people-source", "from project")
      assert has_element?(view, "#share-access-shareholder", "Read")
      assert has_element?(view, "#share-access-shareholder .people-source", "direct")
      assert has_element?(view, "#share-access-sharecolleague .people-source", "from workspace")
      refute has_element?(view, "#share-access-shareoutsider")

      # A private track: its creator runs it, and a share is direct.
      :ok = People.share(ctx.creator, ctx.secret.id, ctx.holder.id)
      view = ctx.creator |> track_page(ctx.secret) |> open_share()
      assert has_element?(view, "#share-access-sharecreator .people-source", "creator")
      assert has_element?(view, "#share-access-shareholder", "Write")
      assert has_element?(view, "#share-access-shareholder .people-source", "direct")
      refute has_element?(view, "#share-access-shareowner")
      refute has_element?(view, "#share-access-sharecolleague")
    end

    test "replaces the invite dialog: no invitations, no invite link", ctx do
      view = ctx.creator |> track_page(ctx.secret) |> open_share()

      assert has_element?(view, "#track-share-button", "Share")
      assert has_element?(view, "#track-share-dialog-dialog[role=dialog][aria-modal=true]")
      refute has_element?(view, "#track-people-invite-form")
      refute render(view) =~ "invite link"
      refute render(view) =~ "Revoke"
    end

    test "the creator switches visibility between the workspace and only people they add", ctx do
      view = ctx.creator |> track_page(ctx.secret) |> open_share()

      # RAV-84: one General access row, a scope dropdown and its role.
      assert has_element?(view, "#share-visibility-scope option[value=private][selected]")

      assert has_element?(
               view,
               "#share-visibility-scope option",
               "Everyone in #{ctx.workspace.name}"
             )

      refute has_element?(view, "#share-visibility-form .role-label")

      view |> form("#share-visibility-form", visibility: "project") |> render_change()
      assert Repo.get!(Track, ctx.secret.id).visibility == :project
      assert has_element?(view, "#share-visibility-scope option[value=project][selected]")
      assert has_element?(view, "#share-visibility-form .role-label", "Write")
      refute has_element?(view, "#share-person-form")

      view |> form("#share-visibility-form", visibility: "private") |> render_change()
      assert Repo.get!(Track, ctx.secret.id).visibility == :private
      assert has_element?(view, "#share-person-form")
    end

    test "a track on the project machine cannot be made private", ctx do
      shared =
        insert_track(
          project: ctx.project,
          title: "On the project machine",
          created_by: ctx.creator.id,
          created_by_login: ctx.creator.login
        )

      view = ctx.creator |> track_page(shared) |> open_share()
      assert has_element?(view, "#share-visibility-scope option[value=project]")
      refute has_element?(view, "#share-visibility-scope option[value=private]")
      assert render(view) =~ "Private tracks need their own machine."
    end

    test "the @-mention list offers workspace members only, as a listbox", ctx do
      view = ctx.creator |> track_page(ctx.secret) |> open_share()

      html = view |> form("#share-person-form", q: "@share") |> render_change()

      assert has_element?(view, "#share-person[role=combobox][aria-expanded=true]")
      assert has_element?(view, "#share-person-options[role=listbox]")
      assert has_element?(view, "#share-option-shareholder[role=option]", "Holly Holder")
      assert has_element?(view, "#share-option-sharecolleague")
      refute html =~ "shareoutsider"
      refute has_element?(view, "#share-option-sharecreator")
    end

    test "adding a member writes the row; they can open the track, and remove takes it away",
         ctx do
      view = ctx.creator |> track_page(ctx.secret) |> open_share()
      view |> form("#share-person-form", q: "shareh") |> render_change()
      view |> element("#share-option-shareholder") |> render_click()

      assert Repo.exists?(
               where(TrackPermission, track_id: ^ctx.secret.id, user_id: ^ctx.holder.id)
             )

      assert has_element?(view, "#share-access-shareholder", "Write")
      assert has_element?(view, "#share-access-shareholder .people-source", "direct")
      assert has_element?(view, "#share-person[aria-expanded=false]")

      view |> element("button[aria-label='Remove @shareholder']") |> render_click()
      refute Repo.exists?(where(TrackPermission, track_id: ^ctx.secret.id))
      assert render(view) =~ "Not shared with anyone yet."
    end

    test "the server refuses a non-member typed in, whatever the browser sends", ctx do
      view = ctx.creator |> track_page(ctx.secret) |> open_share()
      view |> form("#share-person-form", q: "shareoutsider") |> render_submit()
      view |> element("#share-person-form") |> render_submit(%{"login" => "shareoutsider"})

      refute Repo.exists?(where(TrackPermission, track_id: ^ctx.secret.id))

      assert {:error, :not_found} =
               Ravix.Accounts.Access.track_access(ctx.outsider, ctx.secret.id)
    end

    test "copy link copies the track's own URL without printing it (RAV-84)", ctx do
      view = ctx.creator |> track_page(ctx.secret) |> open_share()
      url = "/p/#{ctx.project.id}/t/#{ctx.secret.id}"

      assert has_element?(
               view,
               "#share-link[phx-hook=CopyCode] button[aria-keyshortcuts=c]",
               "Copy link"
             )

      assert has_element?(view, ~s(#share-link[data-copy$="#{url}"]))
      refute has_element?(view, "#share-link code")
      refute view |> element("#track-share-dialog .dialog-body") |> render() =~ ~r{>[^<]*#{url}}

      assert has_element?(
               view,
               "#share-link-hint",
               "The link opens this track only for people who can already see it."
             )
    end

    test "is a popover under Share, with no scrim, and Share says it is open (RAV-84)", ctx do
      view = track_page(ctx.creator, ctx.secret)
      assert has_element?(view, "#track-share-button[aria-expanded=false]")

      open_share(view)
      assert has_element?(view, "#track-share-button[aria-expanded=true]")

      assert has_element?(
               view,
               "#track-share-dialog.share-layer[phx-hook=SharePopover][data-anchor=track-share-button]"
             )

      refute has_element?(view, "#track-share-dialog.scrim")
      refute has_element?(view, ".scrim")

      render_click(view, "dismiss", %{})
      refute has_element?(view, "#track-share-dialog")
      assert has_element?(view, "#track-share-button[aria-expanded=false]")
    end

    test "people with access show whatever the general access", ctx do
      :ok = People.share(ctx.creator, ctx.secret.id, ctx.holder.id)
      view = ctx.creator |> track_page(ctx.secret) |> open_share()
      assert has_element?(view, "#share-access-sharecreator", "Admin")
      assert has_element?(view, "#share-access-shareholder button", "Remove")

      view |> form("#share-visibility-form", visibility: "project") |> render_change()
      assert has_element?(view, "#share-access-sharecreator")
      assert has_element?(view, "#share-access-shareowner", "Admin")
      assert has_element?(view, "#share-access-shareowner .people-source", "owner")
      assert has_element?(view, "#share-access-shareholder")
      assert has_element?(view, "#share-access-sharecolleague .people-source", "from workspace")
      # Nothing to remove on a workspace-visible track: it reaches everyone.
      refute has_element?(view, "#share-access button")
    end

    test "a revoked session changes nothing through the popover", ctx do
      {token, session} = insert_session(ctx.creator)
      conn = Plug.Test.init_test_session(build_conn(), session_token: token)
      {:ok, parent, _} = live(conn, "/p/#{ctx.project.id}/t/#{ctx.secret.id}")
      view = find_live_child(parent, "track-host")
      render_async(view, 5_000)
      open_share(view)

      Repo.delete!(session)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> form("#share-visibility-form", visibility: "project") |> render_change()

      assert Repo.get!(Track, ctx.secret.id).visibility == :private
      refute Repo.exists?(where(TrackPermission, track_id: ^ctx.secret.id))
    end

    test "only whoever manages sharing sees Share; a holder and a member do not", ctx do
      :ok = People.share(ctx.creator, ctx.secret.id, ctx.holder.id)
      holder = track_page(ctx.holder, ctx.secret)
      refute has_element?(holder, "#track-share-button")
      render_click(holder, "dialog", %{"name" => "people"})
      refute has_element?(holder, "#track-share-dialog")
      refute has_element?(holder, "#track-people-invite-form")

      open =
        insert_track(
          project: ctx.project,
          title: "Open work",
          created_by: ctx.creator.id,
          created_by_login: ctx.creator.login
        )

      refute has_element?(track_page(ctx.colleague, open), "#track-share-button")
      # The project's owner manages a project-visible track, as in #299.
      assert has_element?(track_page(ctx.owner, open), "#track-share-button")
    end

    test "the creator's consent note shows on a track they pay for, until acknowledged", ctx do
      Repo.update_all(where(Track, id: ^ctx.secret.id),
        set: [billing_policy: :creator, payer_user_id: ctx.creator.id]
      )

      view = ctx.creator |> track_page(ctx.secret) |> open_share()

      assert has_element?(
               view,
               "#share-consent[role=note]",
               "Collaborators' prompts here use your"
             )

      view |> element("#share-consent button") |> render_click()
      refute has_element?(view, "#share-consent")
      assert Repo.get!(Track, ctx.secret.id).billing_notice_at
    end

    test "with the switch off the track keeps today's people dialog and its link", ctx do
      stub(Ravix.Config, :workspace_access?, fn -> false end)
      view = ctx.creator |> track_page(ctx.secret) |> open_share()

      refute has_element?(view, "#track-share-button")
      assert has_element?(view, "#track-people-invite-form")
      refute has_element?(view, "#track-share-dialog")
    end
  end

  defmodule Host do
    @moduledoc false
    # The popover on its own, for a viewer the header offers no Share to:
    # what it would show them is still `People.sharing/2`'s to decide.
    use Phoenix.LiveView
    on_mount {RavixWeb.Live.Hooks, :require_authenticated_user}

    def mount(_params, %{"track_id" => track_id}, socket),
      do: {:ok, assign(socket, track_id: track_id)}

    def render(assigns) do
      ~H"""
      <.live_component
        module={RavixWeb.Live.ShareDialog}
        id="track-share"
        track_id={@track_id}
        current_user={@current_user}
        session_hash={@session_hash}
      />
      """
    end

    def handle_event("dismiss", _params, socket), do: {:noreply, socket}
    def handle_info(_message, socket), do: {:noreply, socket}
  end

  describe "a Read viewer" do
    setup ctx do
      open =
        insert_track(
          project: ctx.project,
          title: "Open work",
          created_by: ctx.creator.id,
          created_by_login: ctx.creator.login
        )

      insert_track_member(open, ctx.holder, role: :read)

      {:ok, view, _} =
        live_isolated(log_in_user(build_conn(), ctx.holder), Host,
          session: %{"track_id" => open.id}
        )

      %{view: view, open: open}
    end

    test "sees who has access and the general access, with no controls", ctx do
      assert has_element?(ctx.view, "#share-access-shareholder", "Read")
      assert has_element?(ctx.view, "#share-access-shareholder .people-source", "direct")
      assert has_element?(ctx.view, "#share-access-shareowner .people-source", "owner")

      assert has_element?(
               ctx.view,
               "#share-access-sharecolleague .people-source",
               "from workspace"
             )

      assert has_element?(ctx.view, ".share-general-row", "Everyone in #{ctx.workspace.name}")
      assert has_element?(ctx.view, ".share-general-row .role-label", "Write")
      refute has_element?(ctx.view, "#share-visibility-form")
      refute has_element?(ctx.view, "select")
      refute has_element?(ctx.view, "#share-person-form")
      refute has_element?(ctx.view, "#share-access button")
      assert has_element?(ctx.view, "#share-link button", "Copy link")
    end

    test "is refused whatever events the browser sends", ctx do
      target = with_target(ctx.view, "#track-share")
      render_click(target, "visibility", %{"visibility" => "private"})
      render_click(target, "add", %{"login" => "sharecolleague"})
      render_click(target, "search", %{"q" => "share"})

      assert Repo.get!(Track, ctx.open.id).visibility == :project
      refute Repo.exists?(where(TrackPermission, track_id: ^ctx.open.id))
      refute has_element?(ctx.view, "[role=option]")
    end
  end

  describe "an open private track page" do
    setup ctx do
      :ok = People.share(ctx.creator, ctx.secret.id, ctx.holder.id)
      view = track_page(ctx.holder, ctx.secret)
      %{view: view}
    end

    test "is left when the creator removes the permission row", ctx do
      ref = Process.monitor(ctx.view.pid)
      :ok = People.unshare(ctx.creator, ctx.secret.id, ctx.holder.id)
      assert_receive {:DOWN, ^ref, :process, _, {:shutdown, {:redirect, %{to: "/"}}}}, 2_000
    end

    test "is left when the holder is removed from the workspace", ctx do
      ref = Process.monitor(ctx.view.pid)
      :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.holder.id)
      assert_receive {:DOWN, ^ref, :process, _, {:shutdown, {:redirect, %{to: "/"}}}}, 2_000
    end

    test "is left when its creator leaves the workspace", ctx do
      creator_page = track_page(ctx.creator, ctx.secret)
      ref = Process.monitor(creator_page.pid)
      :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.creator.id)
      assert_receive {:DOWN, ^ref, :process, _, {:shutdown, {:redirect, %{to: "/"}}}}, 2_000
    end

    test "drops a delayed result that lands after the row went, notice or not", ctx do
      test = self()

      stub(Tracks, :get, fn user, id, _opts ->
        send(test, {:loading, self()})
        receive do: (:release -> present(user, id))
      end)

      render_click(ctx.view, "retry-load")
      assert_receive {:loading, task}, 2_000

      # Taken away with no notice at all: the lost-PubSub case.
      Repo.delete_all(where(TrackPermission, track_id: ^ctx.secret.id))
      ref = Process.monitor(ctx.view.pid)
      send(task, :release)

      assert_receive {:DOWN, ^ref, :process, _, {:shutdown, {:redirect, %{to: "/"}}}}, 2_000
    end
  end

  describe "the cutover's Inbox note" do
    test "lists who lost access, links to the workspace, and dismisses", ctx do
      insert_track_member(ctx.secret, ctx.outsider)
      {:ok, _} = Cutover.run(apply: true)

      {:ok, view, _} = live(log_in_user(build_conn(), ctx.creator), "/inbox")
      render_async(view, 5_000)

      assert has_element?(view, ".inbox-item", "Access removed")
      assert has_element?(view, ".inbox-item", "@shareoutsider")

      assert has_element?(
               view,
               ~s(a[href="/w/#{ctx.workspace.id}"]),
               "Invite them to the workspace"
             )

      view |> element("button", "Dismiss") |> render_click()
      refute has_element?(view, ".inbox-item", "Access removed")
      assert People.notices(ctx.creator) == []
    end
  end
end

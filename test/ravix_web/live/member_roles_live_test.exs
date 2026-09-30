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

  alias Ravix.Accounts.{Access, Session}
  alias Ravix.Hub.Event
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
    stub(Tracks, :get, fn user, id, _opts -> detail(user, id) end)

    stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _ -> :ok end)

    %{conn: conn, owner: owner, reader: reader, writer: writer, project: project, track: track}
  end

  defp detail(user, id, status \\ nil) do
    with {:ok, access} <- Access.track_access(user, id) do
      row = Repo.get!(Track, id)
      track = Tracks.present(row, role: access.role, level: access.level)

      {:ok,
       %{
         track: if(status, do: %{track | status: status}, else: track),
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

    test "an asleep machine offers a writer Wake and shows a reader the state alone", ctx do
      stub(Tracks, :files, fn _, _, _ -> {:error, :machine_asleep} end)

      {writer, _} = track_page(ctx, ctx.writer)
      assert has_element?(writer, "#panel-asleep [role=status]", "Machine is asleep")
      assert has_element?(writer, "#panel-asleep #panel-wake", "Wake")

      {reader, _} = track_page(ctx, ctx.reader)
      assert has_element?(reader, "#panel-asleep [role=status]", "Machine is asleep")
      refute has_element?(reader, "#panel-wake")
    end

    test "a reader's forged wake is refused by the context and nothing is probed", ctx do
      stub(Tracks, :files, fn _, _, _ -> {:error, :machine_asleep} end)
      reject(&Ravix.Terminal.status/2)
      {view, parent} = track_page(ctx, ctx.reader)

      render_click(view, "wake", %{})
      render_async(view)
      assert render(parent) =~ "Your role on this track is Read. Ask an admin for Write"
      assert has_element?(view, "#panel-asleep")
    end

    # RAV-87: Stop sits where send is while a turn runs, for those who may
    # interrupt. A reader is not shown it, and the context refuses a forged
    # `interrupt` before Fountain is asked.
    test "a running turn offers a writer Stop, and a reader none", ctx do
      stub(Tracks, :get, fn user, id, _opts -> detail(user, id, :running) end)

      {writer, _} = track_page(ctx, ctx.writer)
      assert has_element?(writer, "#composer-stop[aria-label='Stop agent']")

      {reader, _} = track_page(ctx, ctx.reader)
      refute has_element?(reader, "#composer-stop")
      refute has_element?(reader, "button[phx-click=interrupt]")
    end

    test "a reader's forged interrupt is refused by the context", ctx do
      stub(Tracks, :get, fn user, id, _opts -> detail(user, id, :running) end)
      reject(&Ravix.Fountain.interrupt/2)
      {view, parent} = track_page(ctx, ctx.reader)

      render_click(view, "interrupt", %{})
      render_async(view)
      assert render(parent) =~ "Your role on this track is Read. Ask an admin for Write"
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

  # RAV-94: Edit on a queued prompt is Cancel through `PromptQueue.cancel/3`,
  # then its words back in the box. Only the prompt's sender (or the owner)
  # may, a forged id changes nothing, and a revoked session is sent to log in.
  describe "editing a queued prompt" do
    defp enqueue(ctx, user, text) do
      id = Ecto.UUID.generate()

      {:ok, _} =
        PromptQueue.Store.enqueue(ctx.track.id, user.id, user.login, id, %PromptQueue.Body{
          prompt: text,
          images: []
        })

      id
    end

    defp refreshed(view, ctx) do
      send(view.pid, {:hub, Event.new(:queue, ctx.project.id, track_id: ctx.track.id)})
      render_async(view)
      view
    end

    defp status(id), do: PromptQueue.Store.get(id).status

    test "the sender takes it off the queue and gets its words back", ctx do
      id = enqueue(ctx, ctx.writer, "Tidy the scheduler")
      {view, _parent} = track_page(ctx, ctx.writer)
      refreshed(view, ctx)

      assert has_element?(
               view,
               "li.queue-item [phx-value-action=edit][phx-value-id='#{id}']",
               "Edit"
             )

      render_click(view, "queue", %{"action" => "edit", "id" => id})

      assert_push_event(view, "composer:insert", %{text: "Tidy the scheduler"})
      assert status(id) == :cancelled
      render_async(view)
      refute has_element?(view, "li.queue-item [phx-value-id='#{id}']")
    end

    test "a draft in the box is not overwritten, and the prompt stays queued", ctx do
      id = enqueue(ctx, ctx.writer, "Tidy the scheduler")
      {view, _parent} = track_page(ctx, ctx.writer)
      refreshed(view, ctx)

      render_hook(view, "composer-draft", %{"empty" => false})
      render_click(view, "queue", %{"action" => "edit", "id" => id})

      assert has_element?(view, "#thread-error", "Send or clear your draft")
      refute_push_event(view, "composer:insert", _)
      assert status(id) == :queued
    end

    test "another person's prompt offers no Edit, and a forged one is refused", ctx do
      id = enqueue(ctx, ctx.owner, "Owner's plan")
      {view, _parent} = track_page(ctx, ctx.writer)
      refreshed(view, ctx)

      assert has_element?(view, "li.queue-item", "Owner's plan")
      refute has_element?(view, "[phx-value-action=edit]")

      render_click(view, "queue", %{"action" => "edit", "id" => id})
      refute_push_event(view, "composer:insert", _)
      assert status(id) == :queued

      # An id this page does not show (another track's) does nothing at all.
      other = insert_track(project: ctx.project, created_by_login: ctx.owner.login)

      {:ok, _} =
        PromptQueue.Store.enqueue(other.id, ctx.writer.id, "writer", Ecto.UUID.generate(), %{
          prompt: "Elsewhere",
          images: []
        })

      [foreign] = Enum.filter(Repo.all(PromptQueue.Item), &(&1.track_id == other.id))
      render_click(view, "queue", %{"action" => "edit", "id" => foreign.id})
      refute_push_event(view, "composer:insert", _)
      assert status(foreign.id) == :queued
    end

    test "a revoked session is sent to log in and the prompt stays queued", ctx do
      id = enqueue(ctx, ctx.writer, "Tidy the scheduler")
      conn = log_in_user(ctx.conn, ctx.writer)
      {:ok, parent, _} = live(conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
      view = find_live_child(parent, "track-host")
      render_async(view, 5_000)
      refreshed(view, ctx)

      token = Plug.Conn.get_session(conn, :session_token)
      Repo.delete!(Repo.get_by!(Session, token_hash: Ravix.Crypto.sha256(token)))

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
      end)

      assert {:error, {:redirect, %{to: "/login"}}} =
               render_click(view, "queue", %{"action" => "edit", "id" => id})

      assert status(id) == :queued
    end
  end
end

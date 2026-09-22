defmodule RavixWeb.TrackLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Fountain.{FakeTransport, Shapes}
  alias Ravix.Hub.Event
  alias Ravix.{People, Previews, PromptQueue, QueryCount, Repo, Terminal, Tracks, Vitals}
  alias Ravix.PromptQueue.View, as: QueuedPrompt
  alias Ravix.Tracks.{Files, Track, Transcript}

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)

    track =
      insert_track(
        project: project,
        conversation_id: "live-conversation",
        created_by_login: user.login
      )

    stub(Tracks, :get, fn _, id, _opts ->
      row = Repo.get!(Track, id)

      {:ok,
       %{
         track: Tracks.present(row, role: :owner),
         header: blank_header(),
         threads: thread_options(id),
         starters: [%{label: "Start here", prompt: "Build it"}]
       }}
    end)

    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, Transcript.empty("claude")} end)
    # `follow/3` hands back the follower to monitor. The caller's own pid stands
    # in for one that stays alive: monitoring yourself is legal and never fires,
    # so no test sees a spurious recovery. The tests that exercise the recovery
    # itself return a process they can kill.
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _thread_opts -> :ok end)

    stub(Tracks, :files, fn _, _, path ->
      {:ok,
       %Files.Listing{
         path: path || track.workdir,
         truncated: false,
         entries: [%Files.Entry{name: "src", type: "directory", size: 0}]
       }}
    end)

    conn = log_in_user(conn, user)
    {:ok, parent, _} = live(conn, "/p/#{project.id}/t/#{track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    %{conn: conn, parent: parent, view: view, user: user, project: project, track: track}
  end

  test "switching threads changes transcript, composer, and delivery without changing tracks",
       ctx do
    client = FakeTransport.client([], verify: false)
    stub(Ravix.Fountain, :client, fn -> client end)

    {:ok, thread} =
      Tracks.Store.create_thread(%{
        track_id: ctx.track.id,
        title: "Next",
        conversation_id: "next"
      })

    expect(Tracks, :events, fn user, track_id, opts ->
      assert user.id == ctx.user.id
      assert track_id == ctx.track.id
      assert opts[:thread_id] == thread.id
      {:ok, Transcript.empty("claude")}
    end)

    render_hook(ctx.view, "select-thread", %{thread_id: thread.id})
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, "#composer-#{thread.id}")
    assert has_element?(ctx.view, "#selected-thread option[value='#{thread.id}'][selected]")
    ctx.view |> form("#composer-form", %{text: "continue"}) |> render_submit()
    assert [%{thread_id: id}] = PromptQueue.Store.queued_prompts(ctx.track.id)
    assert id == thread.id
    render_hook(ctx.view, "select-thread", %{thread_id: ctx.track.id})
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, "#composer-#{ctx.track.id}")
  end

  test "adding a thread persists and selects it", ctx do
    client = FakeTransport.client([], verify: false)
    stub(Ravix.Fountain, :client, fn -> client end)

    stub(Ravix.Fountain, :get_conversation, fn _, _ ->
      {:ok,
       Shapes.conversation(%{
         "id" => "live-conversation",
         "sandbox_id" => "sandbox"
       })}
    end)

    expect(Ravix.Fountain, :create_conversation, fn _, launch ->
      assert launch.sandbox_id == "sandbox"
      {:ok, Shapes.conversation(%{"id" => "added"})}
    end)

    ctx.view |> element("button", "Add thread") |> render_click()
    render_async(ctx.view, 2_000)
    render_async(ctx.view, 2_000)
    [_, thread] = Tracks.Store.threads_of(ctx.track.id)
    assert thread.conversation_id == "added"
    assert has_element?(ctx.view, "#composer-#{thread.id}")
  end

  test "a forged thread ID cannot switch the page", ctx do
    foreign = insert_track()
    render_hook(ctx.view, "select-thread", %{thread_id: foreign.id})
    assert has_element?(ctx.view, "#composer-#{ctx.track.id}")
    refute has_element?(ctx.view, "#composer-#{foreign.id}")
  end

  for event <- ["select-thread", "add-thread"] do
    @thread_event event
    test "revoked session rejects #{event}", ctx do
      token = Plug.Conn.get_session(ctx.conn, :session_token)
      session = Repo.get_by!(Ravix.Accounts.Session, token_hash: Ravix.Crypto.sha256(token))
      Repo.delete!(session)

      :sys.replace_state(ctx.view.pid, fn state ->
        update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
      end)

      assert {:error, {:redirect, %{to: "/login"}}} =
               render_hook(ctx.view, @thread_event, %{thread_id: ctx.track.id})

      assert length(Tracks.Store.threads_of(ctx.track.id)) == 1
    end
  end

  defp thread_options(id) do
    Enum.map(Tracks.Store.threads_of(id), &%{id: &1.id, title: &1.title, unread: false})
  end

  test "starters and typing use the composer protocol", ctx do
    ctx.view |> element("button", "Start here") |> render_click()
    assert_push_event(ctx.view, "composer:insert", %{text: "Build it"})

    expect(Tracks, :beat, fn user, id, :typing ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      :ok
    end)

    render_hook(ctx.view, "typing")
  end

  test "renaming a track persists the title and updates its header", ctx do
    render_click(ctx.view, "dialog", %{name: "rename"})
    ctx.view |> form("#rename-form", rename_track: [title: "A useful title"]) |> render_submit()
    assert Repo.get!(Track, ctx.track.id).title == "A useful title"

    # The dialog closes on the answer from `Ravix.Tracks.rename/3`; the ribbon
    # above it is re-read for the new name, and that read is a Fountain call
    # this page will not make in its own process.
    refute has_element?(ctx.view, "#rename-dialog")
    render_async(ctx.view)
    assert has_element?(ctx.view, "header button", "A useful title")
  end

  test "a refusal about the title lands on the title, not in a toast", ctx do
    render_click(ctx.view, "dialog", %{name: "rename"})

    # The dialog opens on the name the track has now, so renaming is a
    # correction rather than a blank box.
    assert has_element?(ctx.view, "#rename-title[value='#{ctx.track.title}']")

    html = ctx.view |> form("#rename-form", rename_track: [title: "   "]) |> render_submit()

    # `Ravix.Tracks.rename/3` is still the authority and still refuses; what
    # changed is that its sentence arrives beside the input rather than as a
    # toast at the top of the page, and the dialog stays open to be fixed.
    assert html =~ "A track needs a name."
    assert has_element?(ctx.view, "#rename-form .field p.error", "A track needs a name.")
    assert has_element?(ctx.view, "#rename-dialog")
    assert Repo.get!(Track, ctx.track.id).title == ctx.track.title

    # And the error clears when the next attempt succeeds.
    ctx.view |> form("#rename-form", rename_track: [title: "Second try"]) |> render_submit()
    refute has_element?(ctx.view, "#rename-dialog")
    assert Repo.get!(Track, ctx.track.id).title == "Second try"
  end

  test "wake and interrupt call the scoped track context and refresh state", ctx do
    expect(Tracks, :retry, fn user, id ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      :ok
    end)

    expect(Tracks, :interrupt, fn user, id, _thread_opts ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      :ok
    end)

    ctx.view |> element("button", "Wake / retry") |> render_click()
    render_async(ctx.view)
    ctx.view |> element("button", "Stop") |> render_click()
    # Both are Fountain round trips and run off the page.
    render_async(ctx.view)
    assert has_element?(ctx.view, "#composer-form")
  end

  test "stopping runs off the page, with the button disabled until Fountain answers", ctx do
    parent = self()

    stub(Tracks, :interrupt, fn _, _, _thread_opts ->
      send(parent, {:stopping, self()})

      receive do
        :finish -> :ok
      after
        2_000 -> flunk("the interrupt was never released")
      end
    end)

    ctx.view |> element("button", "Stop") |> render_click()

    assert_receive {:stopping, stopping}
    assert has_element?(ctx.view, "button[phx-click=interrupt][disabled]")
    # Still a page: a dialog opens while the interrupt is out.
    assert render_click(ctx.view, "dialog", %{name: "rename"}) =~ "rename-form"

    send(stopping, :finish)
    render_async(ctx.view)
    refute has_element?(ctx.view, "button[phx-click=interrupt][disabled]")
  end

  @tag capture_log: true
  test "a stop that crashes says so, and not that something failed to load", ctx do
    stub(Tracks, :interrupt, fn _, _, _thread_opts -> raise "Fountain fell over" end)
    ctx.view |> element("button", "Stop") |> render_click()

    render_async(ctx.view)
    html = toasted(ctx)
    assert html =~ "The operation could not finish"
    refute html =~ "Could not finish loading"
    refute has_element?(ctx.view, "button[phx-click=interrupt][disabled]")
  end

  test "failed load can be retried without leaving the track", ctx do
    expect(Tracks, :get, fn _, _, _ -> {:error, {:unavailable, "Offline now"}} end)
    render_click(ctx.view, "retry-load")
    assert toasted(ctx) =~ "Offline now"
    render_click(ctx.view, "retry-load")
    assert render_async(ctx.view) =~ "Start here"
  end

  @tag capture_log: true
  test "a crashed panel reports a recoverable error", ctx do
    expect(Tracks, :files, fn _, _, _ -> raise "remote died" end)
    render_click(ctx.view, "refresh-panel")
    assert toasted(ctx) =~ "Could not finish loading"
    render_click(ctx.view, "refresh-panel")
    assert render_async(ctx.view) =~ "src"
  end

  test "file navigation handles unavailable directories and binary files", ctx do
    ctx.view |> element("button.workspace-file", "src") |> render_click()
    assert render_async(ctx.view) =~ Path.join(ctx.track.workdir, "src")
    expect(Tracks, :files, fn _, _, _ -> {:error, {:unavailable, "Directory offline"}} end)
    render_click(ctx.view, "refresh-panel")
    assert render_async(ctx.view) =~ "Directory offline"
    render_click(ctx.view, "refresh-panel")
    render_async(ctx.view)

    expect(Tracks, :file, fn user, id, path ->
      assert {user.id, id, path} == {ctx.user.id, ctx.track.id, "image.png"}

      {:ok,
       %{path: path, encoding: "base64", content: "secret-binary", size: 128, truncated: true}}
    end)

    render_click(ctx.view, "file", %{path: "image.png"})
    # A file is a Fountain round trip, and the page no longer waits it out.
    assert render_async(ctx.view) =~ "Binary file (128 bytes)"
    refute render(ctx.view) =~ "secret-binary"
    assert render(ctx.view) =~ "File content is truncated"
  end

  test "terminal commands preserve cwd, stderr, and exit status", ctx do
    expect(Terminal, :exec, 2, fn user, id, attrs ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      assert attrs.cwd in [ctx.track.workdir, ctx.track.workdir <> "/src"]

      {:ok,
       %{
         cwd: ctx.track.workdir <> "/src",
         stdout: "out",
         stderr: "problem",
         code: 2,
         timed_out: false,
         duration_ms: 10
       }}
    end)

    ctx.view |> element("#track-terminal") |> render_hook("exec", %{command: "cd src"})
    assert render_async(ctx.view) =~ "Exit 2"
    assert render(ctx.view) =~ "problem"
    ctx.view |> element("button[phx-click=dock][phx-value-name=run]") |> render_click()
    ctx.view |> element("#track-terminal") |> render_hook("exec", %{command: "pwd"})
    assert render_async(ctx.view) =~ "out"
    ctx.view |> element("button[phx-click=clear]") |> render_click()
    refute render(ctx.view) =~ "$ pwd"
  end

  test "terminal errors restore command entry and remain visible", ctx do
    expect(Terminal, :exec, fn _, _, _ -> {:error, {:unavailable, "Machine asleep"}} end)
    ctx.view |> element("#track-terminal") |> render_hook("exec", %{command: "pwd"})
    assert toasted(ctx) =~ "Machine asleep"
    refute has_element?(ctx.view, "input[data-terminal-input][disabled]")
  end

  test "the Run tab explains itself and the Terminal tab does not", ctx do
    hint = "Run a command in this track’s worktree"
    refute render(ctx.view) =~ hint

    ctx.view |> element("button[phx-click=dock][phx-value-name=run]") |> render_click()
    assert has_element?(ctx.view, "#track-terminal p.hint", hint)

    ctx.view |> element("button[phx-click=dock][phx-value-name=terminal]") |> render_click()
    refute render(ctx.view) =~ hint
  end

  test "a session that went without notice cannot run a command through the dock", ctx do
    # The dock is a `live_component`, and the page's session hooks never see
    # a component's events; see `RavixWeb.Live.Hooks`. The redirect answers
    # the event itself, so it is the child's to assert, not the root's.
    reject(&Terminal.exec/3)
    {token, session} = insert_session(ctx.user)
    conn = Plug.Test.init_test_session(build_conn(), session_token: token)
    {:ok, parent, _} = live(conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)

    Repo.delete!(session)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> element("#track-terminal") |> render_hook("exec", %{command: "pwd"})

    assert_redirect(view, "/login")
  end

  test "the dock keeps its own state and its refusals still reach the page", ctx do
    # The dock is a `live_component`, and a component cannot put a flash in
    # the page's own socket -- `put_flash/3` there changes a socket nothing
    # renders. Without the hand-off in `RavixWeb.Live.Result.error/2` the
    # person clicks, nothing happens, and nothing says why.
    expect(Terminal, :exec, fn _, _, _ -> {:error, {:unavailable, "Machine asleep"}} end)
    ctx.view |> element("#track-terminal") |> render_hook("exec", %{command: "pwd"})
    # The sentence goes up twice: the dock hands it to the track page, which
    # has no toasts of its own and hands it on to the workspace. One stack.
    assert toasted(ctx) =~ "Machine asleep"
    refute render(ctx.view) =~ "Machine asleep"

    # And the scrollback is the component's, not the page's: the dock
    # re-renders around it while the transcript beside it does not.
    refute render(ctx.view) =~ ~s(id="track-terminal" hidden)
  end

  test "vitals render both metrics and explicit unavailability", ctx do
    # This stub used to answer `%{cpu: %{percent: 12}, memory: "32MB"}` --
    # neither of which is a field `Vitals` has ever produced. The dock
    # rendered it because it iterated whatever map it was handed, so the test
    # agreed with itself about a readout that does not exist.
    expect(Vitals, :report, fn _, _ ->
      {:ok,
       %Vitals.Report{
         available: true,
         why: nil,
         readings: %Vitals.Readings{
           cpu_cores: 2,
           cpu_busy: 0.12,
           mem_used_bytes: 33_554_432,
           mem_total_bytes: nil,
           disk_used_bytes: nil,
           disk_total_bytes: nil,
           disk_mount: nil
         }
       }}
    end)

    ctx.view |> element("button[phx-click=dock][phx-value-name=vitals]") |> render_click()
    rendered = render(ctx.view)

    assert rendered =~ "Memory used"
    assert rendered =~ "33554432"
    # A reading the machine could not give is left out, not drawn as a blank
    # row: `mem_total_bytes` is nil and no "Memory total" appears.
    refute rendered =~ "Memory total"

    expect(Vitals, :report, fn _, _ ->
      {:ok, %Vitals.Report{available: false, why: :no_machine, readings: nil}}
    end)

    ctx.view |> element("button[phx-click=dock][phx-value-name=vitals]") |> render_click()
    assert render(ctx.view) =~ "no_machine"
  end

  test "a tab or dialog name nobody declared is refused, not shown", ctx do
    # The `in ~w(files changes checks preview)` guards these replace made an
    # undeclared name match no clause. A lookup table that answered `nil`
    # instead would have put the page on a tab that renders nothing, so the
    # table is guarded with `is_map_key/2` and the behaviour is unchanged.
    Process.flag(:trap_exit, true)

    assert catch_exit(render_click(ctx.view, "panel", %{name: "secrets"}))
  end

  test "a name the browser sent still selects the tab and the dialog it names", ctx do
    # The words on the wire are unchanged; what changed is that they stop at
    # `handle_event/3`. Both of these render through an atom comparison now,
    # so they are what says the conversion happened and still lines up.
    render_click(ctx.view, "panel", %{name: "changes"})
    assert has_element?(ctx.view, "button.selected", "Changes")

    render_click(ctx.view, "dialog", %{name: "rename"})
    assert has_element?(ctx.view, "#rename-dialog")

    render_click(ctx.view, "dismiss", %{})
    refute has_element?(ctx.view, "#rename-dialog")
  end

  test "preview actions keep status and use fresh tickets for the iframe", ctx do
    stub(Previews, :status, fn _, _ -> {:ok, preview()} end)
    render_click(ctx.view, "panel", %{name: "preview"})
    render_async(ctx.view)

    answered =
      struct!(preview(),
        logs: "service output",
        open_url: "https://preview.test/__ravix/open#fresh"
      )

    # Two arities, because the two that mint a ticket are the two that need
    # the session hash and the other two are not handed one at all. That
    # distinction only exists once the verb is in the function name.
    for action <- [:open, :restart] do
      expect(Previews, action, fn user, id, hash ->
        assert {user.id, id} == {ctx.user.id, ctx.track.id}
        assert is_binary(hash)
        {:ok, answered}
      end)

      ctx.view |> element("button[phx-value-action='#{action}']") |> render_click()
      assert render_async(ctx.view) =~ "service output"
    end

    for action <- [:logs, :stop] do
      expect(Previews, action, fn user, id ->
        assert {user.id, id} == {ctx.user.id, ctx.track.id}
        {:ok, answered}
      end)

      ctx.view |> element("button[phx-value-action='#{action}']") |> render_click()
      assert render_async(ctx.view) =~ "service output"
    end

    assert has_element?(ctx.view, "iframe[src='https://preview.test/__ravix/open#fresh']")
    assert has_element?(ctx.view, "a[href='/preview/#{ctx.track.id}']")
  end

  test "preview override can be set and cleared", ctx do
    stub(Previews, :status, fn _, _ -> {:ok, preview()} end)
    render_click(ctx.view, "panel", %{name: "preview"})
    render_async(ctx.view)

    expect(Previews, :save_config, fn _, _, config ->
      assert config["command"] == "npm start"
      {:ok, preview()}
    end)

    ctx.view
    |> form("#preview-config-form", preview_config: [command: "npm start"])
    |> render_submit()

    expect(Previews, :save_config, fn _, _, nil -> {:ok, preview()} end)
    ctx.view |> form("#preview-config-form") |> render_submit(%{clear: "true"})
  end

  test "a bad preview configuration is refused on every box that is wrong", ctx do
    render_click(ctx.view, "panel", %{name: "preview"})
    render_async(ctx.view)

    # The real refusal, built by the real parser rather than written out here:
    # `Ravix.Previews.Config` is the authority on which of these three boxes is
    # wrong, and a stub that invented its own shape would keep passing after
    # that changed.
    fields = [directory: "/etc", command: "   ", readiness_path: "nope"]
    {:error, changeset} = Previews.parse_config(Map.new(fields))
    expect(Previews, :save_config, fn _, _, _ -> {:error, changeset} end)

    ctx.view |> form("#preview-config-form", preview_config: fields) |> render_submit()

    # All three at once. A `cond` answered about whichever it reached first, so
    # three wrong boxes took three round trips and only ever pointed at one.
    assert has_element?(ctx.view, "#preview-config-form .field p.error", "relative app directory")
    assert has_element?(ctx.view, "#preview-config-form .field p.error", "honors $PORT")
    assert has_element?(ctx.view, "#preview-config-form .field p.error", "HTTP path on this app")

    # And what was typed is still there to be corrected, because the changeset
    # kept it.
    assert has_element?(ctx.view, "#preview-directory[value='/etc']")
    assert has_element?(ctx.view, "#preview-path[value='nope']")
  end

  test "the queue panel renders what the context really returns, not a stub of it", ctx do
    # Every other queue test stubs `PromptQueue.list/2`, which is how a
    # template bug reached production once: the stub answered with a plain
    # map, the template read it with `item[:error]`, and the real value is a
    # struct with no `Access` behaviour. Nothing here is stubbed, so the row
    # is the one `present/3` actually builds.
    {:ok, _item} =
      PromptQueue.Store.enqueue(
        ctx.track.id,
        ctx.user.id,
        ctx.user.login,
        "browser-smoke-request-id-0001",
        %{prompt: "Waiting on the machine", images: []}
      )

    send(ctx.view.pid, {:hub, Event.new(:queue, ctx.project.id, track_id: ctx.track.id)})
    html = render_async(ctx.view)

    assert html =~ "Waiting on the machine"
    assert html =~ "workspace-queue"
    # The chip is the row's status, and the control is its `can_cancel`, both
    # read off the struct by field.
    assert has_element?(ctx.view, ".workspace-queue .chip")
    assert has_element?(ctx.view, "button[phx-click=queue][phx-value-action=cancel]")
  end

  test "queue cancellation and retry preserve the selected prompt id", ctx do
    stub(PromptQueue, :list, fn _, _, _ ->
      {:ok,
       [
         %QueuedPrompt{
           id: "queued",
           prompt: "Fix this",
           image_count: 0,
           author_login: ctx.user.login,
           created_at: DateTime.utc_now(),
           status: :failed,
           can_cancel: true,
           error: "Offline"
         }
       ]}
    end)

    send(ctx.view.pid, {:hub, Event.new(:queue, ctx.project.id, track_id: ctx.track.id)})
    render_async(ctx.view)

    expect(PromptQueue, :retry, fn user, id, item ->
      assert {user.id, id, item} == {ctx.user.id, ctx.track.id, "queued"}
      :ok
    end)

    ctx.view |> element("button[phx-click=queue]", "Retry") |> render_click()

    expect(PromptQueue, :cancel, fn user, id, item ->
      assert {user.id, id, item} == {ctx.user.id, ctx.track.id, "queued"}
      :ok
    end)

    ctx.view |> element("button[phx-click=queue]", "Cancel") |> render_click()
  end

  test "track invites can be minted, revoked, and members removed", ctx do
    member = insert_user()
    People.Store.add_member(ctx.track.id, member.id, ctx.user.id)
    render_click(ctx.view, "dialog", %{name: "people"})
    ctx.view |> element("button", "Create invite link") |> render_click()
    assert has_element?(ctx.view, "#track-people-dialog a[href*='/j/']")
    ctx.view |> element("button", "Revoke invite link") |> render_click()
    refute has_element?(ctx.view, "#track-people-dialog a[href*='/j/']")
    ctx.view |> element("button[phx-value-login='#{member.login}']") |> render_click()
    refute People.Store.member?(ctx.track.id, member.id)
    render_click(ctx.view, "dismiss")
    refute has_element?(ctx.view, "#track-people-dialog")
  end

  test "pull request form submits a draft and exposes the created link", ctx do
    expect(Tracks, :open_pull, fn user, id, attrs ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      assert attrs["title"] == "Fix"
      assert attrs["draft"] == true
      {:ok, %{url: "https://github.test/pull/1"}}
    end)

    render_click(ctx.view, "dialog", %{name: "pull"})
    ctx.view |> form("#pull-form", title: "Fix", body: "Details") |> render_submit()
    # A GitHub round trip, off the page.
    render_async(ctx.view)
    assert has_element?(ctx.view, "a[href='https://github.test/pull/1']")
    refute has_element?(ctx.view, "#pull-dialog")
  end

  test "opening a pull request disables its button until GitHub answers", ctx do
    parent = self()

    stub(Tracks, :open_pull, fn _, _, _ ->
      send(parent, {:opening, self()})

      receive do
        :finish -> {:error, {:unavailable, "GitHub is not answering."}}
      after
        2_000 -> flunk("the pull request was never released")
      end
    end)

    render_click(ctx.view, "dialog", %{name: "pull"})
    ctx.view |> form("#pull-form", title: "Fix") |> render_submit()

    assert_receive {:opening, opening}
    assert has_element?(ctx.view, "#pull-form button[disabled]")

    send(opening, :finish)
    # A refusal lands in front of the form that caused it, ready to retry;
    # the sentence itself is the workspace's toast, not the track's.
    render_async(ctx.view)
    assert toasted(ctx) =~ "GitHub is not answering."
    assert has_element?(ctx.view, "#pull-dialog")
    refute has_element?(ctx.view, "#pull-form button[disabled]")
  end

  test "closing a track passes the explicit force flag and returns to its project", ctx do
    expect(Tracks, :close, fn user, id, opts ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      assert opts == [force: true]
      :ok
    end)

    render_click(ctx.view, "dialog", %{name: "close"})
    result = ctx.view |> form("#close-form", force: true) |> render_submit()
    assert {:error, {:redirect, %{to: path}}} = result
    assert path == "/p/#{ctx.project.id}"
  end

  test "an event about a sibling track costs this page nothing of its own", ctx do
    # A project's hub carries every track's news to every page on it. This
    # page shows one track, so a turn starting, a queue moving or somebody
    # being invited *elsewhere* is not its business -- and used to cost it a
    # re-read of its own track, its queue and its whole transcript for every
    # one of them.
    #
    # Stated as a comparison rather than as a number because a message costs
    # something before this page's own clauses ever see it: the session and
    # access guards attached at mount run on every one. What is asserted is
    # that a sibling's event costs *that and nothing more*, and that an event
    # this page must act on costs more than that.
    sibling = insert_track(project: ctx.project, slug: "elsewhere")
    render(ctx.view)

    counts =
      for name <- [:people, :tracks, :turn, :queue, :read] do
        hub_queries(ctx, Event.new(name, ctx.project.id, track_id: sibling.id))
      end

    assert [guards] = Enum.uniq(counts),
           "sibling events cost different amounts: #{inspect(counts)}"

    # An event naming this track, and one naming no track at all -- the
    # project's own, which is how a page learns the people it belongs to
    # have changed -- both cost more, because both are acted on.
    assert hub_queries(ctx, Event.new(:people, ctx.project.id, track_id: ctx.track.id)) > guards
    assert hub_queries(ctx, Event.new(:people, ctx.project.id)) > guards
  end

  test "only a turn on this track re-reads the transcript", ctx do
    render(ctx.view)
    track_id = ctx.track.id

    # `:queue` moves the queue and nothing else. The transcript arrives on
    # the follower's stream rather than on the hub, so re-reading it is a
    # repair for a gap, and a turn beginning or failing is the one hub event
    # that means the stream may have missed something.
    queue = hub_queries(ctx, Event.new(:queue, ctx.project.id, track_id: track_id))
    turn = hub_queries(ctx, Event.new(:turn, ctx.project.id, track_id: track_id))
    settings = hub_queries(ctx, Event.new(:settings, ctx.project.id))

    assert turn > queue
    assert turn > settings
  end

  test "a streamed transcript event costs the page no queries at all", ctx do
    render(ctx.view)

    # This is the message that arrives fastest: one per chunk while an agent
    # is talking, to every open page on the track. It used to re-establish
    # the whole of who is asking first -- the session, the track access, and
    # the session again -- six queries a chunk, per viewer.
    event = %{"id" => 1, "turn_id" => "t1", "kind" => "output", "stream" => "acp", "data" => "hi"}

    assert QueryCount.queries(
             fn ->
               send(ctx.view.pid, {:transcript, ctx.track.id, event})
               render(drawn(ctx.view))
             end,
             from: ctx.view.pid
           ) == 0

    # And so does the fifteen-second tick, on the parts that are this page's
    # own. What it costs now is the reads it exists to make.
    counted =
      QueryCount.count(
        fn ->
          send(ctx.view.pid, :refresh)
          render_async(ctx.view)
        end,
        from: ctx.view.pid
      )

    {_result, sources} = counted
    refute "sessions" in sources
  end

  # What one hub event costs the page, in queries, once it has settled.
  # `render_async/1` waits on the async reads outstanding when it is called,
  # and not on any that those start in turn. A load now starts its four reads
  # together, so one call is usually enough --- but the transcript's result
  # can still establish a follower, and a second call costs nothing and keeps
  # the next thing a test measures from paying for somebody else's read.
  # A turn's opening event as the feed serves it with `?prompts=true`, which is
  # where the transcript reads what somebody asked for.
  defp opened(id, turn, prompt) do
    %{
      "id" => id,
      "turn_id" => turn,
      "kind" => "stage",
      "stage" => "turn",
      "state" => "started",
      "blocks" => [%{"kind" => "prompt", "body" => prompt}]
    }
  end

  defp settle(view) do
    render_async(view)
    render_async(view)
  end

  # The track page's flash, which is the workspace's: the nested page has no
  # toasts of its own and hands every sentence up to the page that draws the
  # one stack (see `RavixWeb.Live.Result.flash/3`). Settling the child first
  # is what puts the message in the parent's mailbox before this asks it.
  defp toasted(ctx) do
    render_async(ctx.view)
    render(ctx.parent)
  end

  # Close the window the page collects transcript events in, and hand the view
  # back to be rendered. The page draws on a `:flush_transcript` it sends
  # itself a tenth of a second after the first event of a burst (see
  # `@flush_ms`), so a test that has just handed it one says when the window
  # ends rather than waiting out a clock. Delivering the message the timer
  # would have is also what the timer's own arrival finds already done: a
  # flush with nothing pending draws nothing.
  defp drawn(view) do
    send(view.pid, :flush_transcript)
    view
  end

  test "a read mark on this track costs the guards and nothing more", ctx do
    render(ctx.view)
    sibling = insert_track(project: ctx.project, slug: "elsewhere")

    # The guards' own cost, measured on an event this page provably drops.
    guards = hub_queries(ctx, Event.new(:queue, ctx.project.id, track_id: sibling.id))

    # This page is where a read mark comes from --- on every load, stage and
    # send --- and the dot it clears is the rail's, not this page's. It used
    # to arrive as `:tracks` and re-read the detail, two Fountain round
    # trips, in every other page open on the track each time anybody looked.
    read = Event.new(:read, ctx.project.id, track_id: ctx.track.id, user_id: ctx.user.id)
    assert hub_queries(ctx, read) == guards
  end

  defp hub_queries(ctx, event) do
    QueryCount.queries(
      fn ->
        send(ctx.view.pid, {:hub, event})
        render_async(ctx.view)
      end,
      from: ctx.view.pid
    )
  end

  test "presence updates only affect their own track", ctx do
    send(
      ctx.view.pid,
      {:hub,
       Event.new(:here, ctx.project.id,
         track_id: "other",
         present: [%{login: "outsider", typing: true}]
       )}
    )

    refute render(ctx.view) =~ "outsider"

    send(
      ctx.view.pid,
      {:hub,
       Event.new(:here, ctx.project.id,
         track_id: ctx.track.id,
         present: [%{login: "teammate", typing: true}]
       )}
    )

    assert render(ctx.view) =~ "@teammate is typing"
    send(ctx.view.pid, :refresh)
    assert render_async(ctx.view) =~ "Start here"
  end

  test "streamed transcript updates render text safely and keep newer events during refresh",
       ctx do
    event = %{
      "id" => 1,
      "turn_id" => "turn-one",
      "kind" => "output",
      "stream" => "acp",
      "data" =>
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            update: %{
              sessionUpdate: "agent_message_chunk",
              content: %{type: "text", text: "Hello <script>alert(1)</script>"}
            }
          }
        })
    }

    send(ctx.view.pid, {:transcript, "wrong-track", event})
    refute render(drawn(ctx.view)) =~ "Hello"
    send(ctx.view.pid, {:transcript, ctx.track.id, event})
    assert render(drawn(ctx.view)) =~ "Hello"
    refute has_element?(ctx.view, "#transcript-turns script")

    stage = %{
      "id" => 2,
      "turn_id" => "turn-one",
      "kind" => "stage",
      "stage" => "turn",
      "state" => "completed"
    }

    send(ctx.view.pid, {:transcript, ctx.track.id, stage})
    # The stubbed snapshot is older than the streamed event; it must not erase it.
    assert render_async(drawn(ctx.view)) =~ "Hello"

    expect(Tracks, :events, fn _, _, _thread_opts ->
      {:error, {:unavailable, "Transcript offline"}}
    end)

    send(ctx.view.pid, :refresh)
    assert toasted(ctx) =~ "Transcript offline"
    assert render(ctx.view) =~ "Hello"
  end

  test "a burst of chunks is drawn once, when the window closes", ctx do
    # The cost of drawing a turn is the size of the turn, because a stream
    # keeps no fingerprint per item and so re-sends the whole of one on every
    # insert. Fountain's stream is token-granularity, so "draw what arrived"
    # made a long turn quadratic in its own length, per reader. What bounds it
    # is the window: however many chunks land in one, they are one render.
    chunk = fn id, text ->
      %{
        "id" => id,
        "turn_id" => "burst",
        "kind" => "output",
        "stream" => "acp",
        "data" =>
          Jason.encode!(%{
            jsonrpc: "2.0",
            method: "session/update",
            params: %{
              update: %{
                sessionUpdate: "agent_message_chunk",
                content: %{type: "text", text: text}
              }
            }
          })
      }
    end

    ~w(ne ver mind)
    |> Enum.with_index(1)
    |> Enum.each(fn {text, id} ->
      send(ctx.view.pid, {:transcript, ctx.track.id, chunk.(id, text)})
    end)

    # Read, but not yet drawn: the three chunks are in the page's transcript
    # and the turn on screen has none of them.
    refute render(ctx.view) =~ "nevermind"

    # And then drawn as one turn, with all three in it.
    assert render(drawn(ctx.view)) =~ "nevermind"
  end

  test "a raw event from an instance running the previous release is still understood", ctx do
    # ADR 0003: deploys are rolling, so for one release a follower on an
    # instance running the previous version is still broadcasting Fountain's
    # maps onto this topic rather than `Transcript.Event` structs. The page
    # has to take both or a deploy blanks every open transcript until the
    # last old instance goes. Both shapes must reach the same render.
    raw = fn id, text ->
      %{
        "id" => id,
        "turn_id" => "turn-old",
        "kind" => "output",
        "stream" => "acp",
        "data" =>
          Jason.encode!(%{
            jsonrpc: "2.0",
            method: "session/update",
            params: %{
              update: %{
                sessionUpdate: "agent_message_chunk",
                content: %{type: "text", text: text}
              }
            }
          })
      }
    end

    send(ctx.view.pid, {:transcript, ctx.track.id, raw.(31, "old shape ")})
    send(ctx.view.pid, {:transcript, ctx.track.id, Transcript.Event.from(raw.(32, "new shape"))})

    assert render(drawn(ctx.view)) =~ "old shape new shape"
  end

  test "a follower that goes away is replaced, from the page's own cursor", ctx do
    test_pid = self()

    # The follower is one process for the whole cluster and may be on another
    # instance (ADR 0003). Nothing restarts it when that instance leaves, and
    # nothing else knows which event this page already holds -- so the page
    # monitors it and re-subscribes itself, or it stops receiving the transcript
    # and never finds out.
    follower = spawn(fn -> Process.sleep(:infinity) end)

    expect(Tracks, :follow, fn _user, _id, opts ->
      send(test_pid, {:followed, opts[:after]})
      {:ok, follower}
    end)

    render_click(ctx.view, "retry-load")
    render_async(ctx.view)
    assert_receive {:followed, nil}, 5_000

    # Give the page a cursor of its own, ahead of the stubbed snapshot.
    send(
      ctx.view.pid,
      {:transcript, ctx.track.id, %{"id" => 7, "turn_id" => "t", "kind" => "raw"}}
    )

    expect(Tracks, :follow, fn _user, _id, opts ->
      send(test_pid, {:refollowed, opts[:after]})
      {:ok, self()}
    end)

    expect(Tracks, :events, fn _user, _id, _thread_opts ->
      send(test_pid, :transcript_reread)
      {:ok, Transcript.empty("claude")}
    end)

    Process.exit(follower, :kill)

    # Both halves of the recovery: re-subscribed from event 7 -- not from the
    # beginning, and not from the stubbed snapshot, because only this page knew
    # where it had got to -- and the transcript re-read to close the gap.
    assert_receive {:refollowed, 7}, 5_000
    assert_receive :transcript_reread, 5_000
    assert render_async(ctx.view)
  end

  test "a failed stage reaches the page, with the reason Fountain gave", ctx do
    # #35: this arrived as a stage event and rendered as nothing, so a machine
    # that could not be built looked like a machine still thinking. The reason
    # named a billing page; losing it cost a person an afternoon.
    reason =
      ~s({:denied, {:http, 403, %{"error" => "Add a credit card to start using Sprites."}}})

    send(ctx.view.pid, {
      :transcript,
      ctx.track.id,
      %{
        "id" => 1,
        "turn_id" => nil,
        "kind" => "stage",
        "stage" => "provision",
        "state" => "failed",
        "ts" => "2026-09-10T06:41:17Z",
        "data" => Jason.encode!(%{reason: reason})
      }
    })

    html = render(drawn(ctx.view))
    assert html =~ "provision failed"
    assert html =~ "Add a credit card"

    # Fountain's words, escaped rather than trusted: the reason is upstream text.
    refute has_element?(ctx.view, "#transcript-turns script")
  end

  test "the agent's plan is drawn as a checklist whose state reads without color", ctx do
    plan =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "session/update",
        params: %{
          update: %{
            sessionUpdate: "plan",
            entries: [
              %{content: "Read the code", status: "completed"},
              %{content: "Fix <the> bug", status: "in_progress"},
              %{content: "Open a pull request", status: "pending"}
            ]
          }
        }
      })

    page =
      Transcript.page(
        [
          opened(1, "turn", "Fix it"),
          %{"id" => 2, "turn_id" => "turn", "kind" => "output", "stream" => "acp", "data" => plan}
        ],
        "claude"
      )

    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)

    assert has_element?(ctx.view, ~s|.workspace-plan li.plan-completed [aria-label="done"]|)

    assert has_element?(
             ctx.view,
             ~s|.workspace-plan li.plan-in_progress [aria-label="in progress"]|
           )

    assert has_element?(ctx.view, ~s|.workspace-plan li.plan-pending [aria-label="to do"]|)
    assert has_element?(ctx.view, ".workspace-plan li", "Fix <the> bug")
  end

  test "shared transcript messages name their senders in snapshots and live updates", ctx do
    page =
      Transcript.page(
        [
          opened(1, "mine", PromptQueue.with_author(ctx.user.login, "My message")),
          opened(
            2,
            "theirs",
            "[ravix preview tools for this turn]\nhidden tools\n[/ravix preview tools]\n\n" <>
              PromptQueue.with_author("teammate", "Their message\nSecond line")
          ),
          opened(3, "legacy", "A message without author metadata"),
          opened(4, "system", "[ravix] Open this track.\nInternal instructions")
        ],
        "claude"
      )

    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)

    assert has_element?(ctx.view, "#turns-mine .speaker", "@#{ctx.user.login}")
    assert has_element?(ctx.view, "#turns-theirs .speaker", "@teammate")
    assert has_element?(ctx.view, "#turns-theirs .workspace-prompt", "Their message Second line")
    assert has_element?(ctx.view, "#turns-legacy .speaker", "User")
    assert has_element?(ctx.view, "#turns-system .speaker", "Ravix")
    assert has_element?(ctx.view, "#turns-system .workspace-prompt", "Open this track.")
    refute render(ctx.view) =~ "hidden tools"
    refute render(ctx.view) =~ "[from @"

    send(
      ctx.view.pid,
      {:transcript, ctx.track.id,
       opened(5, "live", PromptQueue.with_author("another-person", "<script>alert(1)</script>"))}
    )

    drawn(ctx.view)
    assert has_element?(ctx.view, "#turns-live .speaker", "@another-person")
    assert has_element?(ctx.view, "#turns-live .workspace-prompt", "<script>alert(1)</script>")
    refute has_element?(ctx.view, "#transcript-turns script")
  end

  test "transcript snapshots render prompts, thinking, tools, and raw output safely", ctx do
    update = fn data ->
      Jason.encode!(%{jsonrpc: "2.0", method: "session/update", params: %{update: data}})
    end

    frames = [
      update.(%{
        sessionUpdate: "agent_thought_chunk",
        content: %{type: "text", text: "Considering the change"}
      }),
      update.(%{
        sessionUpdate: "tool_call",
        toolCallId: "read",
        title: "Read code",
        kind: "read",
        rawInput: %{file_path: "app.ex"}
      }),
      update.(%{
        sessionUpdate: "tool_call_update",
        toolCallId: "read",
        status: "completed",
        content: [%{type: "content", content: %{type: "text", text: "Tool result"}}]
      }),
      "Compiler output <script>alert(1)</script>"
    ]

    events =
      Enum.with_index(frames, 1)
      |> Enum.map(fn {data, id} ->
        %{"id" => id, "turn_id" => "turn", "kind" => "output", "stream" => "acp", "data" => data}
      end)

    page = Transcript.page([opened(0, "turn", "User prompt") | events], "claude")
    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    html = render_async(ctx.view)
    assert html =~ "User prompt"
    assert html =~ "Considering the change"
    assert html =~ "Read code"
    assert html =~ "Tool result"
    assert html =~ "Compiler output"
    refute has_element?(ctx.view, "#transcript-turns script")
  end

  test "a refresh leaves the page answering while the provider is thinking", ctx do
    # `Ravix.Tracks.get/2` is two Fountain round trips, and the page runs it
    # on news it did not ask for: a hub event, a stage event on the transcript,
    # the backstop tick. Run in this process it stopped everything else ---
    # clicks, renders, the transcript arriving --- for however long Fountain
    # took, on every event of a turn.
    parent = self()
    detail = stub_detail(ctx)

    stub(Tracks, :get, fn _, _, _ ->
      send(parent, {:detail_waiting, self()})

      receive do
        :finish -> detail
      after
        2_000 -> flunk("detail read was never released")
      end
    end)

    send(ctx.view.pid, {:hub, Event.new(:settings, ctx.project.id)})
    assert_receive {:detail_waiting, provider}
    refute provider == ctx.view.pid

    # The read is outstanding and the page is still a page.
    assert render_click(ctx.view, "dialog", %{name: "rename"}) =~ "rename-form"
    assert has_element?(ctx.view, "#rename-dialog")

    send(provider, :finish)
    render_async(ctx.view)
    assert has_element?(ctx.view, "#rename-dialog")
  end

  test "a refresh that crashes leaves the page showing what it had", ctx do
    stub(Tracks, :get, fn _, _, _ -> raise "Fountain fell over" end)

    ExUnit.CaptureLog.capture_log(fn ->
      send(ctx.view.pid, {:hub, Event.new(:settings, ctx.project.id)})
      render_async(ctx.view)
    end)

    # Still the track it was showing, and no "could not finish loading" for a
    # read nobody asked for. That message belongs to the reads somebody is
    # waiting on.
    assert render(ctx.view) =~ ctx.track.title
    refute render(ctx.parent) =~ "Could not finish loading"
  end

  test "the run tab says what it is for, and the atom is the one the dock keeps", ctx do
    # `@dock` is an atom from the moment the browser's word crosses `@tabs`;
    # this hint compared it with the string and so was never drawn.
    refute render(ctx.view) =~ "Run a command in this track"
    ctx.view |> element("button[phx-click=dock][phx-value-name=run]") |> render_click()
    assert render(ctx.view) =~ "Run a command in this track"
    ctx.view |> element("button[phx-click=dock][phx-value-name=terminal]") |> render_click()
    refute render(ctx.view) =~ "Run a command in this track"
  end

  test "the live region says when a turn ends, and only then", ctx do
    # Tokens streaming in say nothing: a reader who is not looking --- a
    # screen reader, or somebody scrolled up --- would be interrupted on
    # every chunk. The one moment worth a word is a turn ending.
    region = "#transcript-status[role=status][aria-live=polite]"
    assert has_element?(ctx.view, region)
    refute has_element?(ctx.view, region, "Agent replied")

    send(ctx.view.pid, {:transcript, ctx.track.id, opened(1, "turn-one", "Say hello")})

    send(
      ctx.view.pid,
      {:transcript, ctx.track.id,
       %{
         "id" => 2,
         "turn_id" => "turn-one",
         "kind" => "output",
         "stream" => "acp",
         "data" => "Hi"
       }}
    )

    render(drawn(ctx.view))
    refute has_element?(ctx.view, region, "Agent replied")

    settled = %{"id" => 3, "turn_id" => "turn-one", "kind" => "stage", "stage" => "turn"}
    send(ctx.view.pid, {:transcript, ctx.track.id, Map.put(settled, "state", "completed")})
    render_async(drawn(ctx.view))
    assert has_element?(ctx.view, region, "Agent replied")

    # The next turn starting clears it, so the next ending is a change the
    # region announces rather than the same sentence left standing.
    send(ctx.view.pid, {:transcript, ctx.track.id, opened(4, "turn-two", "Again")})
    render(drawn(ctx.view))
    refute has_element?(ctx.view, region, "Agent replied")

    failed = %{settled | "id" => 5, "turn_id" => "turn-two"}
    send(ctx.view.pid, {:transcript, ctx.track.id, Map.put(failed, "state", "failed")})
    render_async(drawn(ctx.view))
    assert has_element?(ctx.view, region, "Turn failed")

    # The affordance for a reader who has scrolled up is in the scroller the
    # hook is mounted on, where the stylesheet shows it under `.unpinned`.
    assert has_element?(ctx.view, "#transcript-scroll > button.jump-latest[data-jump-latest]")
    assert has_element?(ctx.view, "[data-composer-note][role=status]")
    refute has_element?(ctx.view, ".toasts")
  end

  defp stub_detail(ctx) do
    {:ok,
     %{
       track: Tracks.present(Repo.get!(Track, ctx.track.id), role: :owner),
       header: blank_header(),
       threads: [],
       starters: []
     }}
  end

  describe "the transcript repair read" do
    # A page for `turns`, each one an agent message saying `text`. The frames
    # are ACP because the runtime is, which is what `Ravix.Tracks.Transcript`
    # reads to decide how to lay an event into its turn.
    defp transcript(turns, opts \\ []) do
      {events, _} =
        Enum.flat_map_reduce(turns, Keyword.get(opts, :from, 1), fn {id, text}, next ->
          frame =
            Jason.encode!(%{
              jsonrpc: "2.0",
              method: "session/update",
              params: %{
                update: %{
                  sessionUpdate: "agent_message_chunk",
                  content: %{type: "text", text: text}
                }
              }
            })

          {[
             opened(next, id, id),
             %{
               "id" => next + 1,
               "turn_id" => id,
               "kind" => "output",
               "stream" => "acp",
               "data" => frame
             }
           ], next + 2}
        end)

      Transcript.page(events, "claude")
    end

    defp repair(ctx, page) do
      stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, page} end)
      send(ctx.view.pid, {:hub, Event.new(:turn, ctx.project.id, track_id: ctx.track.id)})
      render_async(ctx.view)
    end

    test "renders a turn that gained content and a turn that arrived after it", ctx do
      html = repair(ctx, transcript([{"t1", "first"}, {"t2", "second"}]))
      assert html =~ "first"
      assert html =~ "second"

      # The common shape: the turns on screen are still the leading turns, one
      # of them says more, and there is a new one after them. Only those two
      # are re-sent; the assertion a page can make is that both are right.
      html =
        repair(ctx, transcript([{"t1", "first"}, {"t2", "second, revised"}, {"t3", "third"}]))

      assert html =~ "first"
      assert html =~ "second, revised"
      assert html =~ "third"
    end

    test "a turn the provider no longer has leaves no ghost on the screen", ctx do
      html = repair(ctx, transcript([{"t1", "first"}, {"t2", "second"}]))
      assert html =~ "second"

      # The provider's own events have moved past the ones this page is
      # holding, so the merge above does not put `t2` back: the answer really
      # is that the turn is gone. Not an append, and `stream_insert/4` has no
      # way to remove anything, which is what the reset is still there for.
      html = repair(ctx, transcript([{"t1", "first"}], from: 50))
      assert html =~ "first"
      refute html =~ "second"
    end

    test "a gap that fills in the middle arrives in order", ctx do
      html = repair(ctx, transcript([{"t1", "first"}, {"t3", "third"}]))
      assert html =~ "first"
      assert html =~ "third"

      # `t2` belongs between them, and `stream_insert/4` appends, so this is
      # the other shape that has to reset rather than be repaired in place.
      html = repair(ctx, transcript([{"t1", "first"}, {"t2", "second"}, {"t3", "third"}]))
      assert [_, _, _] = Regex.scan(~r/first|second|third/, html) |> Enum.uniq()

      positions =
        Enum.map(["first", "second", "third"], fn text ->
          html |> String.split(text) |> hd() |> String.length()
        end)

      assert positions == Enum.sort(positions), "turns rendered out of order"
    end
  end

  for revocation <- [:session, :track] do
    @revocation revocation
    test "#{revocation} revocation rejects a delayed provider result", ctx do
      parent = self()

      stub(Tracks, :files, fn _, _, _ ->
        send(parent, {:provider_waiting, self()})

        receive do
          :finish ->
            {:ok, %Files.Listing{path: "private", entries: [], truncated: false}}
        after
          2_000 -> flunk("provider was never released")
        end
      end)

      render_click(ctx.view, "refresh-panel")
      assert_receive {:provider_waiting, provider}

      case @revocation do
        :session ->
          token = Plug.Conn.get_session(ctx.conn, :session_token)
          Ravix.Accounts.end_session(Ravix.Crypto.sha256(token))

        :track ->
          Repo.update!(Ecto.Changeset.change(ctx.track, closed_at: DateTime.utc_now()))
      end

      send(provider, :finish)
      assert_redirect(ctx.parent, if(@revocation == :session, do: "/login", else: "/"), 1_000)
    end
  end

  # The real struct, not a map that happens to have some of its keys: the
  # template reads these by field, and `@enforce_keys` is what stops this
  # stub drifting away from what `Ravix.Previews.present/1` really returns.
  defp preview do
    %Previews.View{
      state: :stopped,
      available: true,
      unavailable_reason: nil,
      config: nil,
      override: nil,
      error: nil,
      logs: "",
      url: nil
    }
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

  test "the track's chrome is drawn while its transcript is still being read", ctx do
    test_pid = self()

    # `Tracks.events/2` is two Fountain round trips and the largest answer the
    # page waits for. Held open, it stands for the slow half of a real load:
    # everything asserted before it is released is what somebody switching
    # tracks sees immediately rather than after the transcript arrives.
    stub(Tracks, :events, fn _user, _id, _thread_opts ->
      send(test_pid, {:reading_transcript, self()})

      receive do
        :release_transcript -> :ok
      after
        5_000 -> flunk("the transcript read was never released")
      end

      {:ok,
       Transcript.page(
         [
           opened(0, "turn", "An earlier prompt"),
           %{
             "id" => 1,
             "turn_id" => "turn",
             "kind" => "output",
             "stream" => "acp",
             "data" => "hi"
           }
         ],
         "claude"
       )}
    end)

    # Sent from inside the `:load` result, so a `render/1` after it is queued
    # behind that handler and can only see the page it left.
    stub(Tracks, :beat, fn _user, _id, kind ->
      if kind == :watching, do: send(test_pid, :detail_applied)
      :ok
    end)

    {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")

    assert_receive {:reading_transcript, reader}, 5_000
    assert_receive :detail_applied, 5_000

    html = render(view)
    assert html =~ ctx.track.title
    assert html =~ ctx.track.branch
    assert html =~ "Loading conversation…"
    refute html =~ "An earlier prompt"
    # The starters are the empty-conversation answer, and this conversation is
    # not empty --- it is unread. Offering them here would be a wrong answer
    # shown and then taken back.
    refute html =~ "What would you like to work on?"

    send(reader, :release_transcript)
    html = render_async(view)
    assert html =~ "An earlier prompt"
    refute html =~ "Loading conversation…"
  end

  test "a transcript that answers before the track's detail is still drawn", ctx do
    test_pid = self()

    # The reverse race of the test above, and the one that actually broke:
    # the transcript is read separately now, so it can answer while the page
    # still has no `#transcript-turns` to put it in --- and a stream's pending
    # inserts are spent by the next render whether or not that render has the
    # container in it. Holding `Tracks.get/2` open forces that order every
    # time instead of leaving it to which read Fountain answers first.
    stub(Tracks, :get, fn _user, id, _opts ->
      send(test_pid, {:reading_detail, self()})

      receive do
        :release_detail -> :ok
      after
        5_000 -> flunk("the detail read was never released")
      end

      row = Repo.get!(Track, id)

      {:ok,
       %{
         track: Tracks.present(row, role: :owner),
         header: blank_header(),
         threads: [],
         starters: [%{label: "Start here", prompt: "Build it"}]
       }}
    end)

    stub(Tracks, :events, fn _user, _id, _thread_opts ->
      {:ok,
       Transcript.page(
         [
           opened(0, "turn", "An earlier prompt"),
           %{
             "id" => 1,
             "turn_id" => "turn",
             "kind" => "output",
             "stream" => "acp",
             "data" => "hi"
           }
         ],
         "claude"
       )}
    end)

    {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")

    assert_receive {:reading_detail, reader}, 5_000
    send(reader, :release_detail)
    settle(view)

    assert has_element?(view, "#transcript-turns .workspace-prompt", "An earlier prompt")
  end
end

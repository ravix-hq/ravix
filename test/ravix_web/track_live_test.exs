defmodule RavixWeb.TrackLiveTest do
  use RavixWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{People, Previews, PromptQueue, Repo, Terminal, Tracks, Vitals}
  alias Ravix.Tracks.{Track, Transcript}

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

    stub(Tracks, :get, fn _, id ->
      row = Repo.get!(Track, id)

      {:ok,
       %{
         track: Tracks.present(row, role: :owner),
         header: %{},
         starters: [%{label: "Start here", prompt: "Build it"}]
       }}
    end)

    stub(Tracks, :events, fn _, _ -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> :ok end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _ -> :ok end)

    stub(Tracks, :files, fn _, _, path ->
      {:ok,
       %{
         path: path || track.workdir,
         truncated: false,
         entries: [%{name: "src", type: "directory", size: 0}]
       }}
    end)

    conn = log_in_user(conn, user)
    {:ok, parent, _} = live(conn, "/p/#{project.id}/t/#{track.id}")
    view = find_live_child(parent, "track-#{track.id}")
    render_async(view)
    %{conn: conn, parent: parent, view: view, user: user, project: project, track: track}
  end

  test "starters and typing use the composer protocol", ctx do
    ctx.view |> element("button", "Start here") |> render_click()
    assert_push_event(ctx.view, "composer:insert", %{text: "Build it"})

    expect(Tracks, :beat, fn user, id, true ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      :ok
    end)

    render_hook(ctx.view, "typing")
  end

  test "renaming a track persists the title and updates its header", ctx do
    render_click(ctx.view, "dialog", %{name: "rename"})
    ctx.view |> form("#rename-form", title: "A useful title") |> render_submit()
    assert Repo.get!(Track, ctx.track.id).title == "A useful title"
    assert has_element?(ctx.view, "header button", "A useful title")
    refute has_element?(ctx.view, "#rename-dialog")
  end

  test "wake and interrupt call the scoped track context and refresh state", ctx do
    expect(Tracks, :retry, fn user, id ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      :ok
    end)

    expect(Tracks, :interrupt, fn user, id ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      :ok
    end)

    ctx.view |> element("button", "Wake / retry") |> render_click()
    render_async(ctx.view)
    ctx.view |> element("button", "Stop") |> render_click()
    assert has_element?(ctx.view, "#composer-form")
  end

  test "failed load can be retried without leaving the track", ctx do
    expect(Tracks, :get, fn _, _ -> {:error, {:unavailable, "Offline now"}} end)
    render_click(ctx.view, "retry-load")
    assert render_async(ctx.view) =~ "Offline now"
    render_click(ctx.view, "retry-load")
    assert render_async(ctx.view) =~ "Start here"
  end

  @tag capture_log: true
  test "a crashed panel reports a recoverable error", ctx do
    expect(Tracks, :files, fn _, _, _ -> raise "remote died" end)
    render_click(ctx.view, "refresh-panel")
    assert render_async(ctx.view) =~ "Could not finish loading"
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
    assert render(ctx.view) =~ "Binary file (128 bytes)"
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

    render_hook(ctx.view, "exec", %{command: "cd src"})
    assert render_async(ctx.view) =~ "Exit 2"
    assert render(ctx.view) =~ "problem"
    render_click(ctx.view, "dock", %{name: "run"})
    render_hook(ctx.view, "exec", %{command: "pwd"})
    assert render_async(ctx.view) =~ "out"
    render_click(ctx.view, "clear")
    refute render(ctx.view) =~ "$ pwd"
  end

  test "terminal errors restore command entry and remain visible", ctx do
    expect(Terminal, :exec, fn _, _, _ -> {:error, {:unavailable, "Machine asleep"}} end)
    render_hook(ctx.view, "exec", %{command: "pwd"})
    assert render_async(ctx.view) =~ "Machine asleep"
    refute has_element?(ctx.view, "input[data-terminal-input][disabled]")
  end

  test "vitals render both metrics and explicit unavailability", ctx do
    expect(Vitals, :report, fn _, _ ->
      {:ok, %{available: true, vitals: %{cpu: %{percent: 12}, memory: "32MB"}}}
    end)

    render_click(ctx.view, "dock", %{name: "vitals"})
    assert render(ctx.view) =~ "32MB"
    expect(Vitals, :report, fn _, _ -> {:ok, %{available: false, why: :no_machine}} end)
    render_click(ctx.view, "dock", %{name: "vitals"})
    assert render(ctx.view) =~ "no_machine"
  end

  test "preview actions keep status and use fresh tickets for the iframe", ctx do
    stub(Previews, :status, fn _, _ -> {:ok, preview()} end)
    render_click(ctx.view, "panel", %{name: "preview"})
    render_async(ctx.view)

    for action <- ~w(open restart logs stop) do
      expect(Previews, :act, fn user, id, actual, %{session_hash: hash} ->
        assert {user.id, id, actual} == {ctx.user.id, ctx.track.id, action}
        assert is_binary(hash)

        {:ok,
         Map.merge(preview(), %{
           logs: "service output",
           open_url: "https://preview.test/__ravix/open#fresh"
         })}
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

    expect(Previews, :act, fn _, _, "config", %{config: config} ->
      assert config["command"] == "npm start"
      {:ok, preview()}
    end)

    ctx.view |> form("#preview-config-form", command: "npm start") |> render_submit()
    expect(Previews, :act, fn _, _, "config", %{config: nil} -> {:ok, preview()} end)
    ctx.view |> form("#preview-config-form") |> render_submit(%{clear: "true"})
  end

  test "queue cancellation and retry preserve the selected prompt id", ctx do
    stub(PromptQueue, :list, fn _, _ ->
      {:ok,
       [%{id: "queued", prompt: "Fix this", status: :failed, can_cancel: true, error: "Offline"}]}
    end)

    send(ctx.view.pid, {:hub, %{event: "queue"}})
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
    People.add_member(ctx.track.id, member.id, ctx.user.id)
    render_click(ctx.view, "dialog", %{name: "people"})
    ctx.view |> element("button", "Create invite link") |> render_click()
    assert has_element?(ctx.view, "#track-people-dialog a[href*='/j/']")
    ctx.view |> element("button", "Revoke link") |> render_click()
    refute has_element?(ctx.view, "#track-people-dialog a[href*='/j/']")
    ctx.view |> element("button[phx-value-login='#{member.login}']") |> render_click()
    refute People.member?(ctx.track.id, member.id)
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
    assert has_element?(ctx.view, "a[href='https://github.test/pull/1']")
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

  test "presence updates only affect their own track", ctx do
    send(
      ctx.view.pid,
      {:hub,
       %{event: "here", data: %{track_id: "other", present: [%{login: "outsider", typing: true}]}}}
    )

    refute render(ctx.view) =~ "outsider"

    send(
      ctx.view.pid,
      {:hub,
       %{
         event: "here",
         data: %{track_id: ctx.track.id, present: [%{login: "teammate", typing: true}]}
       }}
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
    refute render(ctx.view) =~ "Hello"
    send(ctx.view.pid, {:transcript, ctx.track.id, event})
    assert render(ctx.view) =~ "Hello"
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
    assert render_async(ctx.view) =~ "Hello"
    expect(Tracks, :events, fn _, _ -> {:error, {:unavailable, "Transcript offline"}} end)
    send(ctx.view.pid, :refresh)
    assert render_async(ctx.view) =~ "Transcript offline"
    assert render(ctx.view) =~ "Hello"
  end

  test "transcript snapshots render prompts and tool output", ctx do
    page = Transcript.page([%{"id" => "turn", "prompt" => "User prompt"}], [], "claude")
    stub(Tracks, :events, fn _, _ -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    assert render_async(ctx.view) =~ "User prompt"
  end

  defp preview do
    %{state: :stopped, available: true, unavailable_reason: nil, config: nil, logs: "", url: nil}
  end
end

defmodule RavixWeb.TrackLiveTest do
  use RavixWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Hub.Event
  alias Ravix.{People, Previews, PromptQueue, QueryCount, Repo, Terminal, Tracks, Vitals}
  alias Ravix.PromptQueue.View, as: QueuedPrompt
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
    # `follow/3` hands back the follower to monitor. The caller's own pid stands
    # in for one that stays alive: monitoring yourself is legal and never fires,
    # so no test sees a spurious recovery. The tests that exercise the recovery
    # itself return a process they can kill.
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
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
      for name <- [:people, :tracks, :turn, :queue] do
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
               render(ctx.view)
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

    expect(Tracks, :events, fn _user, _id ->
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

    html = render(ctx.view)
    assert html =~ "provision failed"
    assert html =~ "Add a credit card"

    # Fountain's words, escaped rather than trusted: the reason is upstream text.
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

    page = Transcript.page([%{"id" => "turn", "prompt" => "User prompt"}], events, "claude")
    stub(Tracks, :events, fn _, _ -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    html = render_async(ctx.view)
    assert html =~ "User prompt"
    assert html =~ "Considering the change"
    assert html =~ "Read code"
    assert html =~ "Tool result"
    assert html =~ "Compiler output"
    refute has_element?(ctx.view, "#transcript-turns script")
  end

  for revocation <- [:session, :track] do
    @revocation revocation
    test "#{revocation} revocation rejects a delayed provider result", ctx do
      parent = self()

      stub(Tracks, :files, fn _, _, _ ->
        send(parent, {:provider_waiting, self()})

        receive do
          :finish -> {:ok, %{path: "private", entries: [], truncated: false}}
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
end

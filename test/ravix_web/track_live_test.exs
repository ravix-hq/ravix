defmodule RavixWeb.TrackLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Accounts.{Access, Session, ThreadPreference}
  alias Ravix.Fountain.Error, as: FountainError
  alias Ravix.Fountain.{FakeTransport, Shapes}
  alias Ravix.Hub.Event
  alias Ravix.{People, Previews, PromptQueue, QueryCount, Repo, Terminal, Tracks, Vitals}
  alias Ravix.PromptQueue.View, as: QueuedPrompt
  alias Ravix.Tracks.{Diff, Files, Follower, Setup, Track, TrackMember, Transcript}
  alias RavixWeb.Live.Guard

  alias Ravix.Plans.Progress

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
         starters: [%{label: "Start here", prompt: "Build it"}],
         models: []
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

  test "dedicated lifecycle stages and close warnings stay visible", ctx do
    refute has_element?(ctx.view, "#track-machine-scope")
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    ctx = %{ctx | view: view, parent: parent}
    assert has_element?(ctx.view, "#track-machine-scope", "Shared project machine")

    for {stage, state, text} <- [
          {"creating", :provisioning, "Creating this track's machine…"},
          {"cloning", :provisioning, "Cloning"},
          {"setup", :provisioning, "Running setup…"},
          {"closing", :closing, "Closing… cleaning up this track's machine"}
        ] do
      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Track, ctx.track.id),
          sandbox_layout: :dedicated,
          sandbox_stage: stage,
          sandbox_state: state,
          setup_state: "pending"
        )
      )

      send(
        ctx.view.pid,
        {:hub, %Event{name: :tracks, project_id: ctx.project.id, track_id: ctx.track.id}}
      )

      render(ctx.view)
      render_async(ctx.view)
      assert has_element?(ctx.view, "#track-setup-status", text)
      assert has_element?(ctx.view, "#track-machine-scope", "Own machine")
      assert has_element?(ctx.view, ".thread-add[disabled]")
    end

    render_click(ctx.view, "dialog", %{name: "close"})
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "#close-dialog",
             "uncommitted changes and unpushed commits will be deleted"
           )

    assert has_element?(ctx.view, "#close-machine-changes", "could not be checked")
  end

  test "a ready dedicated track offers rebuild from the header, not the transcript", ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)

    Repo.update!(
      Ecto.Changeset.change(ctx.track, sandbox_layout: :dedicated, sandbox_state: :ready)
    )

    {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    refute has_element?(view, "#rebuild-track-machine")
    refute has_element?(view, "#secrets-changed-rebuild")

    view |> element("button[aria-label='Rebuild machine']") |> render_click()
    render_async(view)
    assert has_element?(view, "#rebuild-dialog", "deletes only this track's machine")
    assert has_element?(view, "#rebuild-dialog", "Sibling tracks are unaffected.")
    assert has_element?(view, "#rebuild-machine-changes", "could not be checked")
    assert has_element?(view, "#rebuild-track-machine input[type=checkbox][required]")

    expect(Tracks, :rebuild_machine, fn user, id, opts ->
      assert {user.id, id, opts} == {ctx.user.id, ctx.track.id, [force: true]}
      :ok
    end)

    view |> form("#rebuild-track-machine", %{force: "true"}) |> render_submit()
    refute has_element?(view, "#rebuild-dialog")
  end

  test "a track on the shared project machine offers no rebuild", ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    Repo.update!(Ecto.Changeset.change(ctx.track, sandbox_state: :ready))

    {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    refute has_element?(view, "button[aria-label='Rebuild machine']")
  end

  test "disconnect health follows the selected thread rather than its project default", ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    stub(Ravix.Config, :dedicated_rollout?, fn -> true end)

    Repo.update!(
      Ecto.Changeset.change(ctx.track, sandbox_layout: :dedicated, sandbox_state: :ready)
    )

    {:ok, second} =
      Tracks.Store.create_thread(%{
        track_id: ctx.track.id,
        title: "Codex",
        runtime: "codex",
        conversation_id: "codex"
      })

    stub(Ravix.Accounts.Inference, :usable?, fn _, runtime, _ -> {:ok, runtime != "codex"} end)
    {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    refute has_element?(view, "#track-agent-health-banner")
    render_click(view, "select-thread", %{"thread_id" => second.id})
    settle(view)

    assert has_element?(
             view,
             "#track-agent-health-banner",
             "This thread uses Codex, which #{ctx.user.login} has disconnected."
           )

    render_click(view, "select-thread", %{"thread_id" => ctx.track.id})
    settle(view)
    refute has_element?(view, "#track-agent-health-banner")
  end

  for wake <- [:turn, :binding, :manual] do
    test "an asleep dedicated files panel waits through refresh ticks then reloads on #{wake}",
         ctx do
      row =
        Repo.update!(
          Ecto.Changeset.change(ctx.track,
            sandbox_layout: :dedicated,
            sandbox_state: :ready,
            sandbox_id: "sleeping-disk"
          )
        )

      send(
        ctx.view.pid,
        {:hub, %Event{name: :tracks, project_id: ctx.project.id, track_id: row.id}}
      )

      settle(ctx.view)

      caller = self()

      stub(Tracks, :files, fn _, _, _ ->
        send(caller, :listing_call)
        {:error, :machine_asleep}
      end)

      render_click(ctx.view, "refresh-panel")
      settle(ctx.view)
      assert_receive :listing_call

      assert has_element?(
               ctx.view,
               ".workspace-panel [role=status]",
               "This track's machine is asleep. Files load when it wakes."
             )

      refute has_element?(ctx.view, ".workspace-panel [role=alert]")

      for _ <- 1..3 do
        send(ctx.view.pid, :refresh)
        settle(ctx.view)
        refute_received :listing_call
      end

      stub(Tracks, :files, fn _, _, _ ->
        send(caller, :listing_call)

        {:ok,
         %Files.Listing{
           path: row.workdir,
           entries: [%Files.Entry{name: "awake.txt", type: "file", size: 1}],
           truncated: false
         }}
      end)

      case unquote(wake) do
        :turn ->
          send(
            ctx.view.pid,
            {:transcript, row.id,
             %Ravix.Tracks.Transcript.Event{
               id: 999,
               turn_id: "wake-turn",
               stream: nil,
               data: nil,
               ts: nil,
               kind: :stage,
               stage: "turn",
               state: "started"
             }}
          )

        :binding ->
          Repo.update!(Ecto.Changeset.change(row, conversation_id: "awake-conversation"))

          send(
            ctx.view.pid,
            {:hub, %Event{name: :tracks, project_id: ctx.project.id, track_id: row.id}}
          )

        :manual ->
          render_click(ctx.view, "refresh-panel")
      end

      settle(ctx.view)
      assert_receive :listing_call
      assert has_element?(ctx.view, ".file-explorer", "awake.txt")
      refute has_element?(ctx.view, ".workspace-panel [role=status]", "asleep")
    end
  end

  for source <- [:file, :directory, :changes] do
    test "suspension while reading #{source} renders the asleep state", ctx do
      case unquote(source) do
        :file ->
          expect(Tracks, :file, fn _, _, _ -> {:error, :machine_asleep} end)
          render_click(ctx.view, "file", %{path: "a.txt"})

        :directory ->
          expect(Tracks, :files, fn _, _, _ -> {:error, :machine_asleep} end)
          render_click(ctx.view, "directory", %{path: "src"})

        :changes ->
          expect(Tracks, :diff, fn _, _ -> {:error, :machine_asleep} end)
          render_click(ctx.view, "panel", %{name: "changes"})
      end

      settle(ctx.view)
      assert has_element?(ctx.view, ".workspace-panel [role=status]", "machine is asleep")
      refute has_element?(ctx.view, ".workspace-panel [role=alert]")
    end
  end

  test "a dedicated binding refreshes mount reads and the dock without waiting for the backstop",
       ctx do
    row =
      Repo.update!(
        Ecto.Changeset.change(ctx.track,
          sandbox_layout: :dedicated,
          sandbox_state: :provisioning,
          conversation_id: nil,
          setup_state: "pending"
        )
      )

    send(
      ctx.view.pid,
      {:hub, %Event{name: :tracks, project_id: ctx.project.id, track_id: ctx.track.id}}
    )

    settle(ctx.view)
    caller = self()

    expect(Tracks, :events, fn _, _, _ ->
      send(caller, :transcript_refreshed)
      {:ok, Transcript.empty("claude")}
    end)

    expect(Tracks, :files, fn _, _, _ ->
      send(caller, :files_refreshed)
      {:ok, %Files.Listing{path: ctx.track.workdir, truncated: false, entries: []}}
    end)

    stub(Terminal, :status, fn _, _, opts ->
      if opts == [passive: true], do: send(caller, :dock_refreshed)
      {:ok, %Terminal.Status{available: true, why: nil, cwd: ctx.track.workdir}}
    end)

    Repo.update!(
      Ecto.Changeset.change(row,
        sandbox_state: :ready,
        sandbox_id: "new-disk",
        conversation_id: "new-conversation",
        setup_state: "ready"
      )
    )

    send(
      ctx.view.pid,
      {:hub, %Event{name: :tracks, project_id: ctx.project.id, track_id: ctx.track.id}}
    )

    settle(ctx.view)
    assert_receive :transcript_refreshed
    assert_receive :files_refreshed
    assert_receive :dock_refreshed
    refute has_element?(ctx.view, "#track-setup-status")
  end

  test "uncertain allocation shows ongoing checks and saved prompts without a retry button",
       ctx do
    Repo.update!(
      Ecto.Changeset.change(ctx.track,
        sandbox_layout: :dedicated,
        sandbox_state: :provisioning,
        sandbox_stage: "creating",
        setup_state: "retry",
        setup_error_code: "sandbox_outcome_unknown",
        setup_error: FountainError.public_message("sandbox_outcome_unknown")
      )
    )

    send(
      ctx.view.pid,
      {:hub, %Event{name: :tracks, project_id: ctx.project.id, track_id: ctx.track.id}}
    )

    settle(ctx.view)
    assert has_element?(ctx.view, "#track-setup-status", "Checking this track's machine…")
    assert has_element?(ctx.view, "#track-setup-status", "Your prompts are saved")
    refute has_element?(ctx.view, "button[phx-click=retry-track]")
    refute render(ctx.view) =~ "next in 0s"
  end

  test "stale secret snapshots explain the required destructive rebuild", ctx do
    Repo.update!(
      Ecto.Changeset.change(ctx.track,
        sandbox_layout: :dedicated,
        setup_state: "failed",
        setup_error_code: "secrets_changed",
        setup_error: "Secrets changed — rebuild to apply"
      )
    )

    send(
      ctx.view.pid,
      {:hub, %Event{name: :tracks, project_id: ctx.project.id, track_id: ctx.track.id}}
    )

    render(ctx.view)
    render_async(ctx.view)
    assert has_element?(ctx.view, "#track-setup-status", "Secrets changed — rebuild to apply")
    refute has_element?(ctx.view, "#track-setup-status", "Retry setup")
    ctx.view |> element("#secrets-changed-rebuild") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, "#rebuild-dialog", "secrets changed")
    assert has_element?(ctx.view, "#rebuild-track-machine input[required]")
  end

  test "only an owner or cutter sees rebuild and forged member events are refused", ctx do
    Repo.update!(
      Ecto.Changeset.change(ctx.track,
        sandbox_layout: :dedicated,
        setup_state: "failed",
        setup_error_code: "secrets_changed"
      )
    )

    member = insert_user()
    insert_track_member(ctx.track, member)

    stub(Tracks, :get, fn user, id, _opts ->
      {:ok,
       %{
         track:
           Tracks.present(Repo.get!(Track, id),
             role: if(user.id == ctx.user.id, do: :owner, else: :member)
           ),
         header: blank_header(),
         threads: thread_options(id),
         starters: [],
         models: []
       }}
    end)

    {:ok, parent, _} =
      live(log_in_user(build_conn(), member), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    settle(view)
    refute has_element?(view, "#secrets-changed-rebuild")
    refute has_element?(view, "button[aria-label='Rebuild machine']")
    render_hook(view, "rebuild-machine", %{force: "true"})
    assert Tracks.Sandbox.Store.operations(ctx.track.id) == []

    # Removing the member turns the same connected page into another user's page.
    Repo.delete!(Repo.get_by!(TrackMember, track_id: ctx.track.id, user_id: member.id))

    render_hook(view, "rebuild-machine", %{force: "true"})
    assert Tracks.Sandbox.Store.operations(ctx.track.id) == []
  end

  test "cached missing funding warns the owner but does not prevent an accepted send", ctx do
    stub(Ravix.Accounts.Inference, :usable?, fn owner, runtime, opts ->
      assert owner.id == ctx.user.id
      assert runtime == ctx.project.runtime
      assert opts == []
      {:ok, false}
    end)

    send(ctx.view.pid, :refresh_agent_health)
    settle(ctx.view)
    assert has_element?(ctx.view, "#track-agent-health-banner", "Reconnect Claude Code")
    assert has_element?(ctx.view, "#track-agent-health-banner", "Your agent connection")
    assert has_element?(ctx.view, "#track-agent-health-banner", "subscription or API key")
    refute has_element?(ctx.view, "#track-agent-owner")
    refute has_element?(ctx.view, "#composer-form button[type=submit][disabled]")

    expect(Tracks, :prompt, fn caller, id, %{prompt: "accepted"} ->
      assert caller.id == ctx.user.id
      assert id == ctx.track.id
      {:ok, %{}}
    end)

    ctx.view |> form("#composer-form", text: "accepted") |> render_submit()
    assert_push_event(ctx.view, "composer:clear", %{})
    ctx.view |> element("#track-agent-health-banner button") |> render_click()
    render(ctx.view)
    render(ctx.parent)
    assert has_element?(ctx.parent, "#account-dialog")
    assert has_element?(ctx.parent, "#agent-claude[aria-pressed=true]")
  end

  test "a queued credential refusal shows the same banner", ctx do
    stub(PromptQueue, :list, fn _, _, _ ->
      {:ok,
       [
         %QueuedPrompt{
           id: "funding",
           prompt: "saved",
           image_count: 0,
           author_login: ctx.user.login,
           created_at: DateTime.utc_now(),
           status: :failed,
           error: "A different reconnect explanation.",
           error_code: "inference_credential_unusable",
           can_cancel: true
         }
       ]}
    end)

    send(ctx.view.pid, :refresh)
    settle(ctx.view)
    assert has_element?(ctx.view, "#track-agent-health-banner", "Sending is paused")
    assert has_element?(ctx.view, "[phx-value-id=funding]", "Retry")
  end

  test "setup credential refusal raises the banner independently of message text", ctx do
    ctx.track
    |> Ecto.Changeset.change(
      setup_state: "failed",
      setup_error: "Reconnect the owner’s agent in account settings.",
      setup_error_code: "inference_credential_unusable"
    )
    |> Repo.update!()

    send(ctx.view.pid, :refresh)
    settle(ctx.view)
    assert has_element?(ctx.view, "#track-agent-health-banner", "Sending is paused")

    assert has_element?(
             ctx.view,
             "#track-agent-health-banner",
             "your agent connection was refused"
           )

    assert has_element?(ctx.view, "#track-agent-health-banner", "saved prompts")
    refute render(ctx.view) =~ "inference_credential_unusable"
  end

  test "capacity is a wait with a reason, and setup in progress cannot be woken", ctx do
    for state <- ["pending", "running", "retry"] do
      ctx.track
      |> Ecto.Changeset.change(
        setup_state: state,
        setup_error_code: "sandbox_at_capacity",
        setup_error: "The machine is busy with other turns; trying again shortly."
      )
      |> Repo.update!()

      send(ctx.view.pid, :refresh)
      settle(ctx.view)
      refute has_element?(ctx.view, "button[phx-click=retry-track]")
    end

    assert has_element?(ctx.view, "#track-setup-status", "Waiting for capacity")
    assert has_element?(ctx.view, "#track-setup-status", "busy with other turns")
    refute has_element?(ctx.view, "#track-setup-status", "attempt")
  end

  test "wake and interrupt refusals give actionable toasts without provider codes", ctx do
    for {event, function} <- [{"retry-track", :retry}, {"interrupt", :interrupt}] do
      expect(Tracks, function, fn _, _, _ ->
        {:error, %FountainError{status: 409, code: "sandbox_at_capacity"}}
      end)

      render_click(ctx.view, event)
      render_async(ctx.view)
      html = render(ctx.parent)
      assert html =~ "The machine is busy with other turns. Try again in a moment."
      refute html =~ "Your prompt is queued"
      refute html =~ "machine_busy"
    end
  end

  test "a draft's capacity refusal says to try again without claiming a queued prompt", ctx do
    open_draft(ctx, draft_options(ctx, runtime: "codex"))

    expect(Tracks, :start_thread, fn _, _, %{"runtime" => "codex"}, %{prompt: "go"} ->
      {:error, %FountainError{status: 409, code: "sandbox_at_capacity"}}
    end)

    ctx.view |> form("#composer-form", %{text: "go"}) |> render_submit()
    render_async(ctx.view)
    html = render(ctx.parent)

    assert has_element?(
             ctx.view,
             "#thread-error",
             "Codex is at capacity on this machine; try again in a moment."
           )

    refute html =~ "Your prompt is queued"
    refute html =~ "machine_busy"
  end

  test "failure cards explain codes and keep diagnostics collapsed", ctx do
    for {code, sentence} <- [
          {"adapter_crashed", "The agent crashed and was restarted."},
          {"session_gone", "The agent session ended."}
        ] do
      page =
        Transcript.page(
          [
            opened(1, "failure", "Do the work"),
            %{
              "id" => 2,
              "turn_id" => "failure",
              "kind" => "stage",
              "stage" => "turn",
              "state" => "failed",
              "data" => Jason.encode!(%{reason: code})
            }
          ],
          "codex"
        )

      stub(Tracks, :events, fn _, _, _ -> {:ok, page} end)
      render_click(ctx.view, "retry-load")
      render_async(ctx.view)
      assert has_element?(ctx.view, ".workspace-failure p", sentence)
      refute has_element?(ctx.view, ".workspace-failure p", code)
      assert has_element?(ctx.view, ".workspace-failure details:not([open]) pre", code)
      assert has_element?(ctx.view, ".workspace-failure p", "your message")
    end
  end

  test "a timeout-only completed reply offers review and retry", ctx do
    page =
      Transcript.page(
        [
          opened(
            1,
            "timeout",
            "[ravix: session context restored]\nhidden context\n[/ravix: session context restored]\n\n[from @teammate] Do the work"
          ),
          %{
            "id" => 2,
            "turn_id" => "timeout",
            "kind" => "output",
            "stream" => "acp",
            "data" =>
              Jason.encode!(%{
                jsonrpc: "2.0",
                method: "session/update",
                params: %{
                  update: %{
                    sessionUpdate: "agent_message_chunk",
                    content: %{type: "text", text: "request timed out"}
                  }
                }
              })
          },
          %{
            "id" => 3,
            "turn_id" => "timeout",
            "kind" => "stage",
            "stage" => "turn",
            "state" => "completed"
          }
        ],
        "claude"
      )

    stub(Tracks, :events, fn _, _, _ -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "#turns-timeout .workspace-failure",
             "Claude Code couldn't reach Anthropic"
           )

    refute has_element?(ctx.view, "#turns-timeout .md", "request timed out")
    ctx.view |> element("button[phx-click=retry-turn]", "Retry message") |> render_click()
    assert_push_event(ctx.view, "composer:retry", %{text: "Do the work", images: false})
  end

  test "structured Codex outage renders a named failure and preserves retry", ctx do
    [start | events] = Ravix.AgentOutageFixture.events("outage")
    start = Map.put(start, "blocks", [%{"kind" => "prompt", "body" => "Fix the outage"}])
    page = Transcript.page([start | events], "codex")
    stub(Tracks, :events, fn _, _, _ -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "#turns-outage .workspace-failure",
             "Codex couldn't reach OpenAI"
           )

    assert has_element?(ctx.view, "#turns-outage .workspace-failure", "after 5 retries")
    ctx.view |> element("button[phx-click=retry-turn]", "Retry message") |> render_click()
    assert_push_event(ctx.view, "composer:retry", %{text: "Fix the outage", images: false})
  end

  for {raw, label} <- [
        {"2026-10-01T09:00:00Z", "Oct 01 at 09:00 UTC"},
        {"unknown reset", "unknown reset"}
      ] do
    test "spent ChatGPT usage shows #{label} to owners and members", ctx do
      ctx.project |> Ecto.Changeset.change(runtime: "codex") |> Repo.update!()
      member = insert_user()
      insert_project_member(ctx.project, member)
      stub(Ravix.Accounts.Inference, :usable?, fn _, _, _ -> {:ok, true} end)

      stub(Ravix.Accounts.Inference, :cached_held, fn owner ->
        assert owner.id == ctx.user.id
        {:ok, [{:codex, :subscription}]}
      end)

      stub(Ravix.Accounts.Inference, :cached_subscription, fn owner ->
        assert owner.id == ctx.user.id

        {:ok,
         %{
           status: "active",
           exhausted_until: unquote(raw),
           account_email: "private@example.com"
         }}
      end)

      for viewer <- [ctx.user, member] do
        {:ok, parent, _} =
          live(log_in_user(build_conn(), viewer), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

        view = find_live_child(parent, "track-host")
        settle(view)

        assert has_element?(
                 view,
                 "#track-agent-health-banner",
                 "#{ctx.user.login}'s ChatGPT usage resets at"
               )

        assert has_element?(
                 view,
                 ~s(#track-agent-health-banner time[datetime="#{unquote(raw)}"]),
                 unquote(label)
               )

        {:ok, overview, _} =
          live(log_in_user(build_conn(), viewer), "/p/#{ctx.project.id}")

        render_async(overview)

        assert has_element?(
                 overview,
                 ~s(#project-agent-health-#{ctx.project.id}-banner time[datetime="#{unquote(raw)}"]),
                 unquote(label)
               )

        refute has_element?(view, "#track-agent-health-banner button")
        refute render(view) =~ "private@example.com"
      end
    end
  end

  test "a member sees the owner's funding status and cannot open a connect form", ctx do
    guest = insert_user()
    insert_track_member(ctx.track, guest)

    stub(Ravix.Accounts.Inference, :usable?, fn owner, _, _ ->
      assert owner.id == ctx.user.id
      {:ok, false}
    end)

    {:ok, parent, _} =
      live(log_in_user(build_conn(), guest), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    settle(view)
    assert has_element?(view, "#track-agent-health-banner", "Ask #{ctx.user.login}")
    assert has_element?(view, "#track-agent-health-banner", "Their agent connection")
    assert has_element?(view, "#track-agent-owner", "Runs on @#{ctx.user.login}'s Claude Code")
    refute has_element?(view, "#track-agent-health-banner button")
    view |> with_target("#track-agent-health") |> render_click("reconnect")
    render(view)
    refute has_element?(parent, "#account-dialog")
    send(parent.pid, {:reconnect_agent, ctx.project.id})
    refute has_element?(parent, "#account-dialog")
  end

  test "unavailable status clears on reconnect and a provider outage stays advisory", ctx do
    for result <- [{:ok, true}, {:error, :offline}] do
      stub(Ravix.Accounts.Inference, :usable?, fn _, _, [] -> result end)
      send(ctx.view.pid, :refresh_agent_health)
      settle(ctx.view)
      refute has_element?(ctx.view, "#track-agent-health-banner")
      refute has_element?(ctx.view, "#composer-form button[type=submit][disabled]")
    end
  end

  test "a revoked session cannot use the reconnect action", ctx do
    assert has_element?(ctx.view, "#track-agent-health-banner button")
    Repo.delete_all(Session)

    assert {:error, {:redirect, %{to: "/login"}}} =
             ctx.view |> element("#track-agent-health-banner button") |> render_click()
  end

  for {state, label} <- [
        {"pending", "Setting up…"},
        {"running", "Setting up…"},
        {"retry", "Retrying (attempt 2 of 3"},
        {"failed", "Setup failed"},
        {"ready", "Ready"}
      ] do
    test "setup #{state} renders its persisted state and reason on Hub updates", ctx do
      ctx.track
      |> Ecto.Changeset.change(
        setup_state: unquote(state),
        setup_attempts: 1,
        setup_error: "The runtime could not initialize.",
        setup_retry_at: DateTime.add(DateTime.utc_now(), 30, :second)
      )
      |> Repo.update!()

      send(ctx.view.pid, {:hub, Event.new(:turn, ctx.project.id, track_id: ctx.track.id)})
      settle(ctx.view)

      if unquote(state) == "ready" do
        # A working track carries no setup line at all.
        refute has_element?(ctx.view, "#track-setup-status")
      else
        assert has_element?(ctx.view, "#track-setup-status", unquote(label))
        assert has_element?(ctx.view, "#track-setup-status", "The runtime could not initialize.")

        assert has_element?(ctx.view, "#track-setup-status", "Prompts will wait") ==
                 unquote(state) in ["pending", "running", "retry"]
      end
    end
  end

  test "retry after an idle page uses the current time for its countdown", ctx do
    :sys.replace_state(ctx.view.pid, fn state ->
      put_in(state.socket.assigns.setup_now, DateTime.add(DateTime.utc_now(), -120, :second))
    end)

    ctx.track
    |> Ecto.Changeset.change(
      setup_state: "retry",
      setup_attempts: 1,
      setup_retry_at: DateTime.add(DateTime.utc_now(), 30, :second)
    )
    |> Repo.update!()

    send(ctx.view.pid, {:hub, Event.new(:turn, ctx.project.id, track_id: ctx.track.id)})
    settle(ctx.view)
    html = render(element(ctx.view, "#track-setup-status"))
    assert [_, seconds] = Regex.run(~r/next in (\d+)s/, html)
    assert String.to_integer(seconds) in 0..30
  end

  test "session loss is a visible system card and overlapping replay does not duplicate it",
       ctx do
    event = %{
      "id" => 101,
      "turn_id" => "restart",
      "kind" => "stage",
      "stage" => "adapter",
      "state" => "restarted",
      "data" => Jason.encode!(%{reason: "session_gone", message: "The session is gone."})
    }

    for _ <- 1..2 do
      send(ctx.view.pid, {:transcript, ctx.track.id, event})
      drawn(ctx.view)
    end

    assert has_element?(
             ctx.view,
             ".workspace-system-card",
             "The agent lost its memory of earlier turns"
           )

    assert has_element?(ctx.view, ".workspace-system-card strong", "Session restarted")

    assert has_element?(
             ctx.view,
             ".workspace-system-card p",
             "The agent lost its memory of earlier turns; Ravix will restate the track's context on your next message."
           )

    assert Enum.count(
             LazyHTML.query(LazyHTML.from_document(render(ctx.view)), ".workspace-system-card")
           ) == 1
  end

  test "revocation blocks setup updates and the retry action", ctx do
    ctx.track |> Ecto.Changeset.change(setup_state: "failed") |> Repo.update!()
    send(ctx.view.pid, {:hub, Event.new(:turn, ctx.project.id, track_id: ctx.track.id)})
    settle(ctx.view)
    Repo.delete_all(Session)

    :sys.replace_state(ctx.view.pid, fn state ->
      update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
    end)

    assert {:error, {:redirect, %{to: "/login"}}} =
             ctx.view |> element("button[phx-click=retry-track]") |> render_click()
  end

  test "exhausted setup shows a Retry setup action", ctx do
    ctx.track
    |> Ecto.Changeset.change(setup_state: "failed", setup_error: "adapter_crashed")
    |> Repo.update!()

    send(ctx.view.pid, {:hub, Event.new(:tracks, ctx.project.id, track_id: ctx.track.id)})
    settle(ctx.view)
    assert has_element?(ctx.view, "[role=alert]", "Setup failed")
    assert has_element?(ctx.view, "button[phx-click=retry-track]", "Retry setup")

    expect(Tracks, :retry, fn user, id, _thread_id ->
      assert user.id == ctx.user.id
      assert id == ctx.track.id
      :ok
    end)

    ctx.view |> element("button[phx-click=retry-track]") |> render_click()
    settle(ctx.view)
  end

  test "setup parked on a sleeping machine says so and offers to wake it", ctx do
    ctx.track
    |> Ecto.Changeset.change(
      setup_state: "running",
      setup_error_code: "sandbox_suspended",
      setup_error: "The project's machine is asleep. Send a prompt or wake it to finish setup."
    )
    |> Repo.update!()

    send(ctx.view.pid, {:hub, Event.new(:tracks, ctx.project.id, track_id: ctx.track.id)})
    settle(ctx.view)
    assert has_element?(ctx.view, "#track-setup-status", "Machine asleep")
    assert has_element?(ctx.view, "#track-setup-status", "Send a prompt or wake it")
    refute has_element?(ctx.view, "#track-setup-status", "Prompts will wait")

    expect(Tracks, :retry, fn user, id, _thread_id ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      :ok
    end)

    ctx.view |> element("button[phx-click=retry-track]", "Wake machine") |> render_click()
    settle(ctx.view)
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

    send(ctx.view.pid, {:hub, Event.new(:tracks, ctx.project.id, track_id: ctx.track.id)})
    settle(ctx.view)

    ctx.view
    |> element("#thread-switcher button[data-thread-id='#{thread.id}']")
    |> render_click()

    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, "#composer-#{thread.id}")

    assert has_element?(
             ctx.view,
             "#thread-switcher [data-thread-id='#{thread.id}'][aria-selected='true']",
             "Next"
           )

    refute has_element?(
             ctx.view,
             "#thread-switcher [data-thread-id='#{ctx.track.id}'][aria-selected='true']"
           )

    ctx.view |> form("#composer-form", %{text: "continue"}) |> render_submit()
    assert [%{thread_id: id}] = PromptQueue.Store.queued_prompts(ctx.track.id)
    assert id == thread.id
    render_hook(ctx.view, "select-thread", %{thread_id: ctx.track.id})
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, "#composer-#{ctx.track.id}")
  end

  test "the first message of a draft creates its thread and queues the prompt on it", ctx do
    client =
      FakeTransport.client(
        [
          {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}}
        ],
        verify: false
      )

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
      assert launch.title == "Explain Prompt Queue"
      {:ok, Shapes.conversation(%{"id" => "added"})}
    end)

    Repo.update!(Ecto.Changeset.change(ctx.project, runtime: "claude"))
    stub(Ravix.Accounts.Inference, :usable?, fn _, "claude", _ -> {:ok, true} end)
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)
    stub(Ravix.Accounts.Inference, :usable_agents, fn _, _ -> {:ok, [:claude]} end)

    stub(Ravix.MachineCache, :catalog, fn _ ->
      {:ok, %Shapes.Catalog{runtimes: ["claude"], models: %{"claude" => [ctx.project.model]}}}
    end)

    stub(Ravix.MachineCache, :machine_of, fn _, _ -> {:ok, nil} end)
    stub(Ravix.MachineCache, :machine_for_track, fn _, _, _ -> {:ok, nil} end)
    ctx.view |> element("#thread-switcher button[aria-label='Add thread']") |> render_click()
    render_async(ctx.view, 2_000)
    refute has_element?(ctx.view, "#new-thread-dialog")
    assert has_element?(ctx.view, "#thread-tab-draft[aria-selected=true]", "New thread")
    assert has_element?(ctx.view, ".thread-default-source", "Project default")
    # Stubbed `Tracks.get` reads the rows, so the page sees the new thread.
    stub(Tracks, :get, fn _, id, _opts ->
      {:ok,
       %{
         track: Tracks.present(Repo.get!(Track, id), role: :owner),
         header: blank_header(),
         threads: thread_options(id),
         starters: [],
         models: []
       }}
    end)

    prompt = "Explain the prompt queue and its retries in detail"
    ctx.view |> form("#composer-form", %{text: prompt}) |> render_submit()
    # The second press lands while the first is out and does nothing.
    ctx.view |> form("#composer-form", %{text: prompt}) |> render_submit()
    render_async(ctx.view, 2_000)
    settle(ctx.view)

    [_, thread] = Tracks.Store.threads_of(ctx.track.id)
    assert thread.conversation_id == "added"
    assert thread.title == "Explain Prompt Queue"

    assert [%{thread_id: thread_id, id: request_id}] =
             PromptQueue.Store.queued_prompts(ctx.track.id)

    assert thread_id == thread.id
    assert has_element?(ctx.view, "#composer-#{thread.id}")
    assert has_element?(ctx.view, "#thread-tab-#{thread.id}[aria-selected=true]")
    refute has_element?(ctx.view, "#thread-tab-draft")
    refute has_element?(ctx.view, "#thread_draft-runtime")
    assert has_element?(ctx.view, ".composer-model")
    assert_push_event(ctx.view, "composer:forget", %{key: key})
    assert key == "track:#{ctx.track.id}:thread:draft:#{request_id}"
    assert_patch(ctx.parent, "/p/#{ctx.project.id}/t/#{ctx.track.id}?thread=#{thread.id}")
  end

  test "a draft opens on the saved personal default and names its source", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.project, runtime: "claude"))
    stub(Ravix.MachineCache, :machine_for_track, fn _, _, _ -> {:ok, nil} end)

    catalog = %Shapes.Catalog{
      runtimes: ["claude"],
      models: %{"claude" => ["anthropic/claude-opus-5"]}
    }

    {:ok, _} =
      ThreadPreference.put(ctx.user, "claude", "anthropic/claude-opus-5", catalog)

    stub(Ravix.Fountain, :client, fn -> FakeTransport.client([], verify: false) end)
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)
    stub(Ravix.MachineCache, :catalog, fn _ -> {:ok, catalog} end)
    stub(Ravix.MachineCache, :machine_of, fn _, _ -> {:ok, nil} end)
    ctx.view |> element("#thread-switcher button[aria-label='Add thread']") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, ".thread-default-source", "Your default: Claude Code")
    assert has_element?(ctx.view, "#thread_draft-model option[selected]", "Claude Opus 5")
    assert has_element?(ctx.view, "#thread-tab-draft", "Claude Code · Claude Opus 5")
    assert has_element?(ctx.view, "#thread-picker option[value=draft][selected]", "New thread")
  end

  test "the draft's agent picker explains unavailable agents and uses product and model names",
       ctx do
    base = draft_options(ctx, owner?: true)

    base = %{
      base
      | runtimes: [
          %{
            runtime: "claude",
            connected: true,
            enabled: true,
            models: ["anthropic/claude-opus-5"]
          },
          %{runtime: "codex", connected: true, enabled: false, models: ["openai/gpt-6-astra"]}
        ]
    }

    open_draft(ctx, base)
    assert has_element?(ctx.view, "label[for=thread_draft-runtime]", "Agent")
    assert has_element?(ctx.view, "#thread_draft-runtime option[value=claude]", "Claude Code")

    assert has_element?(
             ctx.view,
             "#thread_draft-runtime option[value=codex][disabled]",
             "Codex threads on this project aren't available yet"
           )

    assert has_element?(ctx.view, "#thread_draft-model option", "Claude Opus 5")

    for {owner?, reason} <- [
          {true, "Connect to use"},
          {false, "Not connected — #{ctx.user.login} must connect it"}
        ] do
      render_click(ctx.view, "discard-draft")
      settle(ctx.view)
      refute has_element?(ctx.view, "#thread-tab-draft")

      options = %{
        base
        | owner?: owner?,
          runtimes:
            Enum.map(base.runtimes, &%{&1 | enabled: true, connected: &1.runtime == "claude"})
      }

      open_draft(ctx, options)
      assert has_element?(ctx.view, "#thread_draft-runtime option[value=codex][disabled]", reason)
    end
  end

  test "selected thread names its agent in the composer and accessible tab", ctx do
    stub(Tracks, :get, fn _, id, _ ->
      {:ok,
       %{
         track: %{
           Tracks.present(ctx.track, role: :owner)
           | runtime: "codex",
             model: "openai/gpt-6-astra"
         },
         header: blank_header(),
         threads: [
           %{
             id: id,
             title: "Review",
             unread: false,
             runtime: "codex",
             model: "openai/gpt-6-astra",
             status: :running
           }
         ],
         starters: [],
         models: ["openai/gpt-6-astra"]
       }}
    end)

    stub(PromptQueue, :list, fn _, _, _ ->
      {:ok,
       [
         %QueuedPrompt{
           id: "codex-capacity",
           prompt: "waiting",
           image_count: 0,
           author_login: ctx.user.login,
           created_at: DateTime.utc_now(),
           status: :queued,
           error: "capacity",
           error_code: "sandbox_at_capacity",
           can_cancel: true
         }
       ]}
    end)

    send(ctx.view.pid, :refresh)
    settle(ctx.view)

    assert has_element?(
             ctx.view,
             ".workspace-queue p",
             "Codex is at capacity on this machine; your prompt is queued."
           )

    assert has_element?(ctx.view, ".composer-model", "Codex · GPT-6 Astra")
    assert has_element?(ctx.view, ".composer-model", "GPT-6 Astra")

    assert has_element?(
             ctx.view,
             "#thread-switcher button[title='Review · Codex · GPT-6 Astra'][aria-label='Review · Codex · GPT-6 Astra · Running']"
           )
  end

  test "a draft's refusals name the agent and owner in plain words and keep the draft", ctx do
    open_draft(ctx, draft_options(ctx, runtime: "codex"))

    for {code, message} <- [
          {"agent_not_connected", "#{ctx.user.login} hasn't connected Codex."},
          {"guest_runtime_disabled", "Codex threads on this project aren't available yet."},
          {"invalid_runtime", "Choose Claude Code or Codex."},
          {"invalid_model", "Choose one of Codex's models."}
        ] do
      expect(Tracks, :start_thread, fn _, _, _, _ -> {:error, {:conflict, code, message}} end)
      ctx.view |> form("#composer-form", %{text: "keep me"}) |> render_submit()
      render_async(ctx.view)
      assert has_element?(ctx.view, "#thread-error[role=alert]", message)
      assert has_element?(ctx.view, "#thread-tab-draft[aria-selected=true]")
      assert has_element?(ctx.view, "#thread_draft-runtime option[value=codex][selected]")
      refute_push_event(ctx.view, "composer:clear", %{})
      refute_push_event(ctx.view, "composer:forget", %{})
    end

    assert [_] = Tracks.Store.threads_of(ctx.track.id)
  end

  test "a disconnected agent refuses a prompt beside the composer without clearing it", ctx do
    expect(Tracks, :prompt, fn _, _, %{prompt: "keep this draft"} ->
      {:error, {:conflict, "agent_not_connected", "internal connection details"}}
    end)

    render_submit(ctx.view, "send", %{"text" => "keep this draft"})

    assert has_element?(
             ctx.view,
             "#thread-error",
             "#{ctx.user.login} hasn't connected Claude Code."
           )

    refute render(ctx.view) =~ "internal connection details"
    refute_push_event(ctx.view, "composer:clear", %{})
  end

  test "failed guest attachment explains the retry and home-agent alternative", ctx do
    open_draft(ctx, draft_options(ctx, runtime: "codex"))

    expect(Tracks, :start_thread, fn _, _, _, _ ->
      {:error,
       %FountainError{status: 422, code: "sandbox_runtime_mismatch", message: "provider details"}}
    end)

    ctx.view |> form("#composer-form", %{text: "go"}) |> render_submit()
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "#thread-error[role=alert]",
             "Couldn't start a Codex thread on this machine; try again or use Claude Code."
           )

    refute render(ctx.view) =~ "sandbox_runtime_mismatch"
    refute render(ctx.view) =~ "provider details"
  end

  test "owners connect an agent inline from the draft and late ticks are discarded", ctx do
    options = %{
      draft_options(ctx, owner?: true)
      | runtimes: [
          %{
            runtime: "claude",
            connected: true,
            enabled: true,
            models: ["anthropic/claude-opus-5"]
          },
          %{runtime: "codex", connected: false, enabled: true, models: ["openai/gpt-6-astra"]}
        ]
    }

    stub(Ravix.Accounts.Inference, :held, fn _ -> {:ok, []} end)
    stub(Ravix.Accounts.Inference, :subscription, fn _ -> {:ok, nil} end)

    stub(Ravix.Accounts.Inference, :link_status, fn _ ->
      {:ok, %{enabled?: true, pending: nil}}
    end)

    open_draft(ctx, options)
    assert has_element?(ctx.view, "#thread-tab-draft", "Claude Code")

    ctx.view
    |> element("button[phx-click=connect-thread-agent][phx-value-runtime=codex]")
    |> render_click()

    render_async(ctx.view)

    ctx.view
    |> element(".thread-connections button[phx-click=choose-kind][phx-value-kind=api_key]")
    |> render_click()

    expect(Ravix.Accounts.Inference, :connect, fn user, %{agent: :codex, value: "fixture"} ->
      assert user.id == ctx.user.id
      {:ok, user}
    end)

    expect(Tracks, :thread_options, fn _, _ ->
      {:ok, %{options | runtimes: Enum.map(options.runtimes, &%{&1 | connected: true})}}
    end)

    ctx.view
    |> form(".thread-connections form", credential: %{value: "fixture"})
    |> render_submit()

    render_async(ctx.view)
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "#thread_draft-runtime option[value=codex][selected]",
             "Connected"
           )

    assert has_element?(ctx.view, "#thread_draft-model option[selected]", "GPT-6 Astra")
    assert has_element?(ctx.view, "#thread-tab-draft", "Codex · GPT-6 Astra")
    refute has_element?(ctx.view, ".thread-connections form")
    render_click(ctx.view, "discard-draft")
    settle(ctx.view)
    send(ctx.view.pid, {:agent_panel, "thread-connect-old", {:poll_link, make_ref()}})
    render(ctx.view)
    refute has_element?(ctx.view, "#thread-tab-draft")
    refute has_element?(ctx.view, ".thread-connections")
  end

  test "thread tabs mark the selected thread and unread ones, and pressing the current tab stays put",
       ctx do
    {:ok, other} =
      Tracks.Store.create_thread(%{track_id: ctx.track.id, title: "Review", conversation_id: "r"})

    stub(Tracks, :get, fn _, id, _ ->
      threads = Enum.map(thread_options(id), &%{&1 | unread: true})

      {:ok,
       %{
         track: Tracks.present(Repo.get!(Track, id), role: :owner),
         header: blank_header(),
         threads: threads,
         starters: [],
         models: []
       }}
    end)

    send(ctx.view.pid, {:hub, Event.new(:tracks, ctx.project.id, track_id: ctx.track.id)})
    settle(ctx.view)

    selected = "#thread-switcher button[data-thread-id='#{ctx.track.id}']"
    unread = "#thread-switcher button[data-thread-id='#{other.id}']"

    assert has_element?(
             ctx.view,
             "nav#thread-switcher[aria-label='Threads'][phx-hook='ThreadTabs']"
           )

    assert has_element?(ctx.view, "#thread-tablist[role=tablist]")

    assert has_element?(
             ctx.view,
             ".track-conversation > #thread-switcher ~ #transcript-scroll[role=tabpanel][aria-labelledby='thread-tab-#{ctx.track.id}']"
           )

    refute has_element?(ctx.view, "#thread-picker option", "Idle")
    assert has_element?(ctx.view, "#thread-picker option[value='#{other.id}']", "(unread)")

    assert has_element?(
             ctx.view,
             selected <>
               "[aria-selected='true'][tabindex='0'][role='tab'][aria-controls='transcript-scroll']"
           )

    refute has_element?(ctx.view, selected <> " .thread-unread")

    assert has_element?(
             ctx.view,
             unread <> "[aria-selected='false'][tabindex='-1'] .thread-unread",
             "(unread)"
           )

    assert has_element?(ctx.view, unread, "Review")
    assert has_element?(ctx.view, unread <> "[aria-label='Review · Agent · Idle (unread)']")

    ctx.view |> element(".thread-picker") |> render_change(%{thread_id: other.id})
    settle(ctx.view)
    assert has_element?(ctx.view, "#thread-picker option[value='#{other.id}'][selected]")
    ctx.view |> element(".thread-picker") |> render_change(%{thread_id: ctx.track.id})
    settle(ctx.view)

    reject(&Tracks.events/3)
    ctx.view |> element(selected) |> render_click()
    assert has_element?(ctx.view, "#composer-#{ctx.track.id}")
  end

  test "Follower events update other thread states without disabling or replacing the composer",
       ctx do
    other = activity_thread(ctx)
    tab = "#thread-switcher [data-thread-id='#{other.id}']"
    refute has_element?(ctx.view, "#threads-working")

    for {state, label} <- [
          {"queued", "Queued"},
          {"started", "Running"},
          {"failed", "Failed"},
          {"started", "Running"},
          {"completed", "Idle"}
        ] do
      broadcast_activity(other.id, state)
      assert has_element?(ctx.view, tab <> "[aria-label='Thread 2 · Codex · #{label}']")
      assert has_element?(ctx.view, "#composer-#{ctx.track.id}:not([disabled])")

      if state == "started" do
        assert has_element?(
                 ctx.view,
                 "#threads-working[role=status]",
                 "Thread 2 (Codex) is working in this checkout"
               )
      else
        refute has_element?(ctx.view, "#threads-working")
      end
    end

    broadcast_activity(other.id, "started")
    render(ctx.view)
    render_click(ctx.view, "select-thread", %{thread_id: other.id})
    settle(ctx.view)
    refute has_element?(ctx.view, "#threads-working")
    assert has_element?(ctx.view, "#composer-#{other.id}:not([disabled])")
    broadcast_activity(ctx.track.id, "started")
    assert has_element?(ctx.view, "#threads-working", "is working in this checkout")
  end

  test "a new delivery clears the previous idle event while its turn is still pending", ctx do
    other = activity_thread(ctx)
    tab = "#thread-switcher [data-thread-id='#{other.id}']"
    broadcast_activity(other.id, "completed")
    assert has_element?(ctx.view, tab <> "[aria-label='Thread 2 · Codex · Idle']")

    stub(Tracks, :get, fn _, id, _opts ->
      row = Repo.get!(Track, id)

      threads =
        Enum.map(thread_options(id), fn thread ->
          if thread.id == other.id, do: Map.put(thread, :status, :pending), else: thread
        end)

      {:ok,
       %{
         track: Tracks.present(row, role: :owner),
         header: blank_header(),
         threads: threads,
         starters: [],
         models: []
       }}
    end)

    send(
      ctx.view.pid,
      {:hub,
       %Event{
         name: :turn,
         project_id: ctx.project.id,
         track_id: ctx.track.id,
         thread_id: other.id
       }}
    )

    settle(ctx.view)
    assert has_element?(ctx.view, tab <> "[aria-label='Thread 2 · Codex · Queued']")
    broadcast_activity(other.id, "started")
    assert has_element?(ctx.view, tab <> "[aria-label='Thread 2 · Codex · Running']")
    broadcast_activity(other.id, "completed")
    assert has_element?(ctx.view, tab <> "[aria-label='Thread 2 · Codex · Idle']")
  end

  test "suspension settles the transcript and thread tab without a turn-done event", ctx do
    activity_thread(ctx)
    events = Ravix.SuspensionFixture.events()
    tab = "#thread-switcher [data-thread-id='#{ctx.track.id}']"
    send(ctx.view.pid, {:transcript, ctx.track.id, hd(events)})
    assert has_element?(ctx.view, tab, "Running")

    stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.page(events, "plain")} end)
    for event <- tl(events), do: send(ctx.view.pid, {:transcript, ctx.track.id, event})
    render_async(drawn(ctx.view))
    assert has_element?(ctx.view, tab, "Failed")
    assert has_element?(ctx.view, "#transcript-status", "Turn failed")
    assert render(ctx.view) =~ Ravix.SuspensionFixture.message()
    refute has_element?(ctx.view, "#threads-working")
  end

  test "opening a suspended transcript restores the failed thread tab", ctx do
    activity_thread(ctx)

    stub(Tracks, :events, fn _, _, _ ->
      {:ok, Transcript.page(Ravix.SuspensionFixture.events(), "plain")}
    end)

    {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    assert has_element?(view, "#thread-switcher [data-thread-id='#{ctx.track.id}']", "Failed")
    assert render(view) =~ Ravix.SuspensionFixture.message()
  end

  test "a single thread never warns about itself", ctx do
    send(
      ctx.view.pid,
      {:transcript, ctx.track.id, %{"kind" => "stage", "stage" => "turn", "state" => "started"}}
    )

    refute has_element?(ctx.view, "#threads-working")
  end

  test "a track-only member follows only threads in the shared track", ctx do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project, conversation_id: "shared")
    private = insert_track(project: project, conversation_id: "private")
    People.Store.add_member(track.id, ctx.user.id, owner.id)
    stub_activity_follow()

    {:ok, other} =
      Tracks.Store.create_thread(%{
        track_id: track.id,
        title: "Shared thread",
        runtime: "codex",
        conversation_id: "shared-other"
      })

    {:ok, parent, _} = live(ctx.conn, "/p/#{project.id}/t/#{track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    broadcast_activity(other.id, "started")
    assert has_element?(view, "#threads-working", "Shared thread")

    send(
      view.pid,
      {:transcript, private.id, %{"kind" => "stage", "stage" => "turn", "state" => "started"}}
    )

    refute has_element?(view, "[data-thread-id='#{private.id}']")
    refute render(view) =~ private.title
  end

  test "a revoked session cannot receive sibling activity", ctx do
    other = activity_thread(ctx)
    token = Plug.Conn.get_session(ctx.conn, :session_token)
    Ravix.Accounts.end_session(Ravix.Crypto.sha256(token))
    broadcast_activity(other.id, "started")
    assert_redirect(ctx.parent, "/login", 1_000)
  end

  defp activity_thread(ctx) do
    {:ok, thread} =
      Tracks.Store.create_thread(%{
        track_id: ctx.track.id,
        title: "Thread 2",
        runtime: "codex",
        conversation_id: "activity-other"
      })

    stub_activity_follow()
    send(ctx.view.pid, :refresh)
    settle(ctx.view)
    thread
  end

  defp stub_activity_follow do
    stub(Tracks, :follow, fn user, track_id, opts ->
      id = opts[:thread_id]
      assert {:ok, _} = Access.thread_access(user, track_id, id)
      Phoenix.PubSub.subscribe(Ravix.PubSub, Follower.topic(id))
      {:ok, self()}
    end)
  end

  defp broadcast_activity(id, state) do
    Phoenix.PubSub.broadcast(
      Ravix.PubSub,
      Follower.topic(id),
      {:transcript, id, %{"kind" => "stage", "stage" => "turn", "state" => state}}
    )
  end

  test "the thread row is absent with one thread when threads cannot be added" do
    one = [%{id: "a", title: "Main", unread: false}]
    two = one ++ [%{id: "b", title: "Side", unread: true}]
    tabs = fn assigns -> render_component(&RavixWeb.TrackLive.thread_tabs/1, assigns) end

    assert tabs.(threads: one, thread_id: "a", enabled: false) |> String.trim() == ""

    html = tabs.(threads: two, thread_id: "a", enabled: false)
    assert html =~ ~s(data-thread-id="b")
    refute html =~ "Add thread"

    html = tabs.(threads: one, thread_id: "a", enabled: true, adding: true)
    assert html =~ ~r/aria-label="Add thread"[^>]*disabled/s
  end

  test "a forged thread ID cannot switch the page", ctx do
    foreign = insert_track()
    render_hook(ctx.view, "select-thread", %{thread_id: foreign.id})
    assert has_element?(ctx.view, "#composer-#{ctx.track.id}")
    refute has_element?(ctx.view, "#composer-#{foreign.id}")
  end

  for event <- ["select-thread", "draft-thread", "connect-thread-agent", "rebuild-machine"] do
    @thread_event event
    test "revoked session rejects #{event}", ctx do
      token = Plug.Conn.get_session(ctx.conn, :session_token)
      session = Repo.get_by!(Session, token_hash: Ravix.Crypto.sha256(token))
      Repo.delete!(session)

      :sys.replace_state(ctx.view.pid, fn state ->
        update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
      end)

      assert {:error, {:redirect, %{to: "/login"}}} =
               render_hook(ctx.view, @thread_event, %{
                 thread_id: ctx.track.id,
                 runtime: "codex",
                 force: "true"
               })

      assert length(Tracks.Store.threads_of(ctx.track.id)) == 1
    end
  end

  describe "the machine state chip" do
    # The row as the page's next detail read will present it, then the hub
    # message that makes the page read it again.
    defp machine_row(ctx, attrs) do
      Repo.update!(Ecto.Changeset.change(Repo.get!(Track, ctx.track.id), attrs))

      send(
        ctx.view.pid,
        {:hub, %Event{name: :tracks, project_id: ctx.project.id, track_id: ctx.track.id}}
      )

      render(ctx.view)
      render_async(ctx.view)
    end

    defp chip(view, label, detail) do
      assert has_element?(
               view,
               "#track-machine-state[role=status][aria-live=polite] .dot.#{String.downcase(label)}"
             )

      assert has_element?(view, "#track-machine-state", label)

      if detail do
        assert has_element?(
                 view,
                 "#track-machine-state[aria-describedby=track-machine-detail][title=\"#{detail}\"]"
               )

        assert has_element?(view, "#track-machine-detail.sr-only", detail)
      else
        refute has_element?(view, "#track-machine-detail")
        # A narrow header shows only the dot, so the word is its tooltip.
        assert has_element?(view, "#track-machine-state[title=\"#{label}\"]")
      end
    end

    test "says each state with its detail", ctx do
      now = DateTime.utc_now()
      opened = [opened_at: now, setup_state: "ready", setup_error: nil]
      dedicated = [sandbox_layout: :dedicated, sandbox_state: :ready, sandbox_stage: "ready"]

      for {attrs, label, detail} <- [
            {opened, "Idle", nil},
            {dedicated ++
               [
                 sandbox_state: :provisioning,
                 sandbox_action: :open,
                 sandbox_stage: "creating",
                 setup_state: "pending"
               ], "Starting", "Creating this track's machine…"},
            {dedicated ++
               [sandbox_stage: "setup", sandbox_state: :provisioning, setup_state: "running"],
             "Starting", "Running setup…"},
            {dedicated ++
               opened ++
               [
                 sandbox_state: :provisioning,
                 sandbox_action: :rebuild,
                 sandbox_stage: "creating",
                 setup_state: "pending"
               ], "Restarting", "Creating this track's machine…"},
            {dedicated ++ opened ++ [sandbox_suspended_at: now], "Asleep",
             "Your next message wakes it."},
            {opened ++
               [setup_state: "failed", setup_error: "The opening turn failed to clone the repo."],
             "Error", "The opening turn failed to clone the repo."},
            {dedicated ++ [sandbox_state: :closing, sandbox_stage: "closing"], "Closing",
             "Closing… cleaning up this track's machine"},
            {[sandbox_layout: :shared, sandbox_state: nil, sandbox_suspended_at: now] ++ opened,
             "Idle", nil}
          ] do
        machine_row(ctx, attrs)
        chip(ctx.view, label, detail)
      end
    end

    test "follows a turn as it starts and ends, and a rebuild until the machine is back",
         ctx do
      machine_row(ctx, opened_at: DateTime.utc_now(), sandbox_layout: :dedicated)
      chip(ctx.view, "Idle", nil)

      turn = fn state ->
        send(
          ctx.view.pid,
          {:transcript, ctx.track.id,
           %{"id" => 1, "turn_id" => "t1", "kind" => "stage", "stage" => "turn", "state" => state}}
        )

        render(ctx.view)
      end

      turn.("started")
      chip(ctx.view, "Working", "The agent is taking a turn.")
      turn.("done")
      chip(ctx.view, "Idle", nil)

      machine_row(ctx,
        sandbox_state: :provisioning,
        sandbox_action: :rebuild,
        sandbox_stage: "creating",
        setup_state: "pending"
      )

      chip(ctx.view, "Restarting", "Creating this track's machine…")
      machine_row(ctx, sandbox_stage: "setup", setup_state: "running")
      chip(ctx.view, "Restarting", "Running setup…")
      machine_row(ctx, sandbox_state: :ready, sandbox_stage: "ready", setup_state: "ready")
      chip(ctx.view, "Idle", nil)
    end

    test "a machine the probe finds running is not called asleep in the dock", ctx do
      stub(Terminal, :status, fn _, _, _ ->
        {:ok, %Terminal.Status{available: true, why: nil, cwd: ctx.track.workdir}}
      end)

      machine_row(ctx,
        opened_at: DateTime.utc_now(),
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_suspended_at: DateTime.utc_now()
      )

      {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
      view = find_live_child(parent, "track-host")
      settle(view)
      assert has_element?(view, "#track-machine-status", "Idle.")
      refute has_element?(view, "#track-machine-status", "Asleep")
    end

    test "a sleep or wake is re-read from the row and the memo, not Fountain", ctx do
      parent = self()

      stub(Tracks, :get, fn _, id, opts ->
        send(parent, {:get, opts[:fresh]})

        {:ok,
         %{
           track: Tracks.present(Repo.get!(Track, id), role: :owner),
           header: blank_header(),
           threads: thread_options(id),
           starters: [],
           models: []
         }}
      end)

      send(
        ctx.view.pid,
        {:hub, %Event{name: :machine, project_id: ctx.project.id, track_id: ctx.track.id}}
      )

      render_async(ctx.view)
      assert_received {:get, false}
      refute_received {:get, true}
    end

    test "the dock's status line uses the same words", ctx do
      stub(Terminal, :status, fn _, _, _ ->
        {:ok, %Terminal.Status{available: false, why: :no_sprite, cwd: ctx.track.workdir}}
      end)

      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Track, ctx.track.id),
          opened_at: DateTime.utc_now(),
          sandbox_layout: :dedicated,
          sandbox_state: :ready,
          sandbox_suspended_at: DateTime.utc_now()
        )
      )

      {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
      view = find_live_child(parent, "track-host")
      settle(view)
      chip(view, "Asleep", "Your next message wakes it.")
      assert has_element?(view, "#track-machine-status", "Asleep. Your next message wakes it.")
      refute render(view) =~ "asleep or unreachable"
    end
  end

  describe "the model menu" do
    setup ctx do
      # `status` and `model` stand for the live conversation, which is
      # Fountain's; the rest is the row.
      serve = fn status, model ->
        stub(Tracks, :get, fn _, id, _ ->
          track = %{
            Tracks.present(Repo.get!(Track, id), role: :owner)
            | status: status,
              model: model
          }

          {:ok,
           %{
             track: track,
             header: blank_header(),
             threads: thread_options(id),
             starters: [],
             models: ["anthropic/claude-opus-5", "anthropic/claude-sonnet-5"]
           }}
        end)

        send(ctx.view.pid, {:hub, Event.new(:tracks, ctx.project.id, track_id: ctx.track.id)})
        settle(ctx.view)
      end

      serve.(:ready, nil)
      %{serve: serve}
    end

    test "names what the conversation runs and marks the project's model as the default", ctx do
      assert has_element?(ctx.view, ".model-default-hint", "Also your default for new threads")
      assert has_element?(ctx.view, "#model-menu [phx-value-model=\"\"]", "Project default")
      assert has_element?(ctx.view, "#model-trigger:not([disabled])", "Claude Sonnet 5")

      assert has_element?(
               ctx.view,
               "#model-menu [role=menuitemradio][aria-checked=true]",
               "Project default"
             )

      assert has_element?(
               ctx.view,
               ~s(#model-menu [phx-value-model="anthropic/claude-opus-5"][aria-checked=false])
             )

      # A conversation on its own model shows that one, still offering the default.
      ctx.serve.(:ready, "anthropic/claude-opus-5")
      assert has_element?(ctx.view, "#model-trigger", "Claude Opus 5")

      assert has_element?(
               ctx.view,
               ~s(#model-menu [phx-value-model="anthropic/claude-opus-5"][aria-checked=true])
             )
    end

    test "choosing one changes the shown conversation through the scoped context", ctx do
      user_id = ctx.user.id
      track_id = ctx.track.id

      # The page's first thread is the track's own conversation, named by
      # the track's id.
      expect(Tracks, :set_model, fn %{id: ^user_id},
                                    ^track_id,
                                    ^track_id,
                                    "anthropic/claude-opus-5" = model ->
        {:ok, model}
      end)

      ctx.view
      |> element(~s(#model-menu [phx-value-model="anthropic/claude-opus-5"]))
      |> render_click()

      render_async(ctx.view)
      assert has_element?(ctx.view, "#model-trigger:not([disabled])")
    end

    test "choosing the project default clears the personal preference through the context", ctx do
      expect(Tracks, :set_model, fn _, _, _, nil -> {:ok, nil} end)
      ctx.view |> element(~s(#model-menu [phx-value-model=""])) |> render_click()
      render_async(ctx.view)
    end

    test "a refusal is said, and the page keeps the model it had", ctx do
      stub(Tracks, :set_model, fn _, _, _, _ ->
        {:error,
         {:conflict, "conversation_busy", "Wait for the turn to finish, then change the model."}}
      end)

      ctx.view
      |> element(~s(#model-menu [phx-value-model="anthropic/claude-opus-5"]))
      |> render_click()

      render_async(ctx.view)
      assert toasted(ctx) =~ "Wait for the turn to finish"
      assert has_element?(ctx.view, "#model-trigger", "Claude Sonnet 5")
    end

    test "is disabled while a turn runs, and a plain label with no catalog", ctx do
      ctx.serve.(:running, nil)
      assert has_element?(ctx.view, "#model-trigger[disabled]")

      html =
        render_component(&RavixWeb.TrackLive.model_menu/1,
          model: "anthropic/claude-sonnet-5",
          project_model: "anthropic/claude-sonnet-5",
          models: []
        )

      assert html =~ ~s(class="composer-model")
      refute html =~ "model-menu"
    end

    test "a revoked session cannot change it", ctx do
      reject(&Tracks.set_model/4)
      token = Plug.Conn.get_session(ctx.conn, :session_token)
      Repo.delete!(Repo.get_by!(Session, token_hash: Ravix.Crypto.sha256(token)))

      :sys.replace_state(ctx.view.pid, fn state ->
        update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
      end)

      assert {:error, {:redirect, %{to: "/login"}}} =
               render_hook(ctx.view, "set-model", %{model: "anthropic/claude-opus-5"})
    end
  end

  describe "a draft thread" do
    test "+ adds a draft on the personal default with no dialog, and pressing it again reuses it",
         ctx do
      expect(Tracks, :thread_options, 1, fn user, id ->
        assert {user.id, id} == {ctx.user.id, ctx.track.id}
        {:ok, draft_options(ctx, source: :person)}
      end)

      ctx.view |> element("#thread-switcher button[aria-label='Add thread']") |> render_click()
      render_async(ctx.view)

      refute has_element?(ctx.view, "#new-thread-dialog")
      refute has_element?(ctx.view, "#new-thread-form")
      assert has_element?(ctx.view, "#thread-tab-draft[aria-selected=true]", "New thread")
      assert has_element?(ctx.view, "#thread-tab-draft", "Claude Code · Claude Opus 5")
      assert has_element?(ctx.view, "#thread-tab-#{ctx.track.id}[aria-selected=false]")
      assert has_element?(ctx.view, "#transcript-scroll[aria-labelledby=thread-tab-draft]")

      assert has_element?(
               ctx.view,
               "#draft-thread-empty",
               "Your first message starts this thread."
             )

      refute has_element?(ctx.view, "#transcript-turns")
      assert has_element?(ctx.view, ".thread-default-source", "Your default: Claude Code")
      assert has_element?(ctx.view, ".draft-default-hint", "Also your default for new threads")
      refute has_element?(ctx.view, "#model-trigger")
      key = draft_key(ctx.view)

      ctx.view |> element("#thread-switcher button[aria-label='Add thread']") |> render_click()
      render_async(ctx.view)

      assert 1 ==
               ctx.view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#thread-tab-draft")
               |> Enum.count()

      assert draft_key(ctx.view) == key

      # The close button discards it and goes back to the thread it left.
      ctx.view |> element("#thread-draft-discard") |> render_click()
      settle(ctx.view)
      refute has_element?(ctx.view, "#thread-tab-draft")
      assert has_element?(ctx.view, "#composer-#{ctx.track.id}")
      assert has_element?(ctx.view, "#thread-tab-#{ctx.track.id}[aria-selected=true]")
      assert_push_event(ctx.view, "composer:forget", %{key: ^key})
    end

    test "switching threads keeps the draft, its picks and its text; a reload drops it", ctx do
      open_draft(ctx, draft_options(ctx))
      key = draft_key(ctx.view)

      ctx.view
      |> form("#composer-form", %{
        thread_draft: %{runtime: "claude", model: "anthropic/claude-sonnet-5"}
      })
      |> render_change(%{_target: ["thread_draft", "model"]})

      render_hook(ctx.view, "select-thread", %{thread_id: ctx.track.id})
      settle(ctx.view)
      assert has_element?(ctx.view, "#composer-#{ctx.track.id}")
      assert has_element?(ctx.view, "#thread-tab-#{ctx.track.id}[aria-selected=true]")
      assert has_element?(ctx.view, "#thread-tab-draft[aria-selected=false]", "Claude Sonnet 5")
      refute has_element?(ctx.view, "#thread_draft-runtime")

      # The narrow picker offers the draft too, and choosing it comes back.
      assert has_element?(ctx.view, "#thread-picker option[value=draft]", "New thread")
      ctx.view |> element("#thread-picker-form") |> render_change(%{thread_id: "draft"})
      assert has_element?(ctx.view, "#thread-tab-draft[aria-selected=true]")
      assert draft_key(ctx.view) == key
      assert has_element?(ctx.view, "#thread_draft-model option[selected]", "Claude Sonnet 5")

      {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
      reloaded = find_live_child(parent, "track-host")
      settle(reloaded)
      refute has_element?(reloaded, "#thread-tab-draft")
    end

    test "the agent and model are explicit picks sent with the first message", ctx do
      open_draft(ctx, draft_options(ctx))
      key = draft_key(ctx.view)

      ctx.view
      |> form("#composer-form", %{thread_draft: %{runtime: "codex"}})
      |> render_change(%{_target: ["thread_draft", "runtime"]})

      assert has_element?(ctx.view, "#thread_draft-runtime option[value=codex][selected]")
      assert has_element?(ctx.view, "#thread_draft-model option[selected]", "GPT-6 Astra")
      assert has_element?(ctx.view, "#thread-tab-draft", "Codex · GPT-6 Astra")

      ctx.view
      |> form("#composer-form", %{thread_draft: %{runtime: "codex", model: "openai/gpt-5.6"}})
      |> render_change(%{_target: ["thread_draft", "model"]})

      assert has_element?(ctx.view, "#thread-tab-draft", "Codex · GPT-5.6")

      expect(Tracks, :start_thread, fn user, id, attrs, payload ->
        assert {user.id, id} == {ctx.user.id, ctx.track.id}

        assert attrs == %{
                 "runtime" => "codex",
                 "model" => "openai/gpt-5.6",
                 "preference_explicit" => "true"
               }

        assert "track:#{ctx.track.id}:thread:draft:#{payload.request_id}" == key
        assert payload.prompt == "Use Codex"
        {:error, {:conflict, "not_open", "The track's machine is not ready."}}
      end)

      ctx.view |> form("#composer-form", %{text: "Use Codex"}) |> render_submit()
      render_async(ctx.view)
      assert has_element?(ctx.view, "#thread-error", "Couldn't start a Codex thread")
      assert has_element?(ctx.view, "#thread-tab-draft[aria-selected=true]", "Codex · GPT-5.6")
      assert draft_key(ctx.view) == key
    end

    test "an untouched default is not an explicit pick", ctx do
      open_draft(ctx, draft_options(ctx))

      expect(Tracks, :start_thread, fn _, _, attrs, _ ->
        assert attrs == %{
                 "runtime" => "claude",
                 "model" => "anthropic/claude-opus-5",
                 "preference_explicit" => "false"
               }

        {:error, :not_found}
      end)

      ctx.view |> form("#composer-form", %{text: "defaults"}) |> render_submit()
      render_async(ctx.view)
    end

    test "a collaborator never sees another person's draft", ctx do
      member = insert_user()
      insert_project_member(ctx.project, member)

      {:ok, parent, _} =
        live(log_in_user(build_conn(), member), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

      theirs = find_live_child(parent, "track-host")
      settle(theirs)

      open_draft(ctx, draft_options(ctx))
      send(theirs.pid, {:hub, Event.new(:tracks, ctx.project.id, track_id: ctx.track.id)})
      settle(theirs)
      refute has_element?(theirs, "#thread-tab-draft")
      refute render(theirs) =~ "New thread"
      assert has_element?(ctx.view, "#thread-tab-draft")
    end

    test "a revoked session cannot start a thread from its draft", ctx do
      open_draft(ctx, draft_options(ctx))
      reject(&Tracks.start_thread/4)
      token = Plug.Conn.get_session(ctx.conn, :session_token)
      Repo.delete!(Repo.get_by!(Session, token_hash: Ravix.Crypto.sha256(token)))

      :sys.replace_state(ctx.view.pid, fn state ->
        update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
      end)

      assert {:error, {:redirect, %{to: "/login"}}} =
               render_submit(ctx.view, "send", %{"text" => "after sign-out"})

      assert [_] = Tracks.Store.threads_of(ctx.track.id)
    end

    test "a removed member cannot start a thread from their draft", ctx do
      member = insert_user()
      membership = insert_project_member(ctx.project, member)

      {:ok, parent, _} =
        live(log_in_user(build_conn(), member), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

      view = find_live_child(parent, "track-host")
      settle(view)
      open_draft(%{ctx | view: view}, draft_options(ctx))
      reject(&Tracks.start_thread/4)
      Repo.delete!(membership)

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns.track_guard, &%{&1 | stale?: true})
      end)

      assert {:error, {:redirect, %{to: "/"}}} =
               render_submit(view, "send", %{"text" => "still a member?"})

      assert [_] = Tracks.Store.threads_of(ctx.track.id)
    end
  end

  defp draft_key(view) do
    [key] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("textarea[data-draft-key]")
      |> LazyHTML.attribute("data-draft-key")

    key
  end

  # What `Tracks.thread_options/2` answers for a Claude-home project whose
  # payer has both agents: the draft's picker, without Fountain.
  defp draft_options(ctx, overrides \\ []) do
    runtime = Keyword.get(overrides, :runtime, "claude")

    Map.merge(
      %{
        runtime: runtime,
        model: if(runtime == "codex", do: "openai/gpt-6-astra", else: "anthropic/claude-opus-5"),
        source: :project,
        home_runtime: "claude",
        owner_login: ctx.user.login,
        owner?: true,
        runtimes: [
          %{
            runtime: "claude",
            connected: true,
            enabled: true,
            models: ["anthropic/claude-opus-5", "anthropic/claude-sonnet-5"]
          },
          %{
            runtime: "codex",
            connected: true,
            enabled: true,
            models: ["openai/gpt-6-astra", "openai/gpt-5.6"]
          }
        ]
      },
      Map.new(Keyword.delete(overrides, :runtime))
    )
  end

  defp open_draft(ctx, options) do
    stub(Tracks, :thread_options, fn _, _ -> {:ok, options} end)
    ctx.view |> element("#thread-switcher button[aria-label='Add thread']") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, "#thread-tab-draft[aria-selected=true]")
  end

  defp thread_options(id) do
    Enum.map(
      Tracks.Store.threads_of(id),
      &%{id: &1.id, title: &1.title, runtime: &1.runtime, unread: false}
    )
  end

  test "assigned items occupy one collapsed row and reveal status-ordered lines and details",
       ctx do
    items =
      Enum.with_index([:done, :unassigned, :in_review, :in_progress], fn status, position ->
        %{
          id: "compact-#{position}",
          title: "Item #{position}",
          position: position,
          brief: "Private brief #{position}",
          acceptance: "Verify #{position}",
          notes: [],
          status: status,
          status_available: true,
          pull:
            if(status in [:done, :in_review],
              do: %{
                number: 231 + position,
                url: "https://github.com/acme/app/pull/#{231 + position}"
              }
            )
        }
      end)

    summary = %{items: items, plan: nil, progress: Progress.summarize(items)}

    expect(Ravix.Plans, :track_summary, fn user, id ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      {:ok, summary}
    end)

    send(ctx.view.pid, :refresh_plan_items)
    settle(ctx.view)
    # The items are a chip in the header, not a panel over the transcript.
    assert has_element?(
             ctx.view,
             "header.track-crumbs .track-plan-toggle[aria-expanded=false]",
             "Plan items · 4 items"
           )

    refute has_element?(ctx.view, "#transcript-scroll .track-plan-items")
    assert has_element?(ctx.view, ".track-plan-popover[hidden]")
    assert has_element?(ctx.view, ".track-plan-summary", "1 of 4 done")
    assert has_element?(ctx.view, ".track-plan-summary", "25% complete")
    assert has_element?(ctx.view, ".track-plan-summary", "2 WIP")
    assert has_element?(ctx.view, ".track-plan-summary", "1 unstarted")
    refute has_element?(ctx.view, ".track-plan-summary ~ .track-plan-summary")
    refute has_element?(ctx.view, ".track-plan-item-row")
    refute render(ctx.view) =~ "Private brief"
    ctx.view |> element(".track-plan-toggle") |> render_click()
    html = render(ctx.view) |> LazyHTML.from_document()

    assert html |> LazyHTML.query(".track-plan-list > li") |> LazyHTML.attribute("id") ==
             [
               "assigned-item-compact-2",
               "assigned-item-compact-3",
               "assigned-item-compact-1",
               "assigned-item-compact-0"
             ]

    assert has_element?(ctx.view, ".plan-status", "In review")
    assert has_element?(ctx.view, ".plan-status", "Merged")
    assert has_element?(ctx.view, "a[href='https://github.com/acme/app/pull/233']", "#233")
    refute has_element?(ctx.view, ".track-plan-detail")
    ctx.view |> element("#assigned-item-compact-2 .track-plan-item-title") |> render_click()
    assert has_element?(ctx.view, ".track-plan-detail", "Private brief 2")
    assert has_element?(ctx.view, "#track-note-compact-2")
    ctx.view |> element("#assigned-item-compact-0 .track-plan-item-title") |> render_click()
    refute has_element?(ctx.view, "#track-note-compact-2")
    assert has_element?(ctx.view, "#track-note-compact-0")

    # Escape closes the panel again.
    ctx.view |> element(".track-plan-items") |> render_keydown(%{"key" => "Escape"})
    assert has_element?(ctx.view, ".track-plan-toggle[aria-expanded=false]")
    refute has_element?(ctx.view, ".track-plan-list > li")
  end

  test "the header uses the plan title and completed items have a quiet summary", ctx do
    {:ok, plan} =
      Ravix.Plans.create(ctx.user, ctx.project.id, %{
        "title" => "Small fixes: task state, machine stats and navigation",
        "items" => [%{"id" => "complete", "title" => "An item title"}]
      })

    Repo.get!(Ravix.Plans.Item, "complete")
    |> Ecto.Changeset.change(track_id: ctx.track.id)
    |> Repo.update!()

    stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)

    stub(Ravix.GitHub, :plan_pulls, fn _, _, _ ->
      {:ok,
       %{
         pulls: [
           %{
             state: :merged,
             number: 231,
             url: "https://github.com/acme/app/pull/231",
             plan_item_ids: ["complete"]
           }
         ],
         complete: true
       }}
    end)

    send(ctx.view.pid, :refresh_plan_items)
    settle(ctx.view)

    assert has_element?(
             ctx.view,
             ".track-plan-summary .track-plan-title[title='#{plan.title}'][href='/p/#{ctx.project.id}/plans?plan=#{plan.id}']",
             "Plan · #{plan.title}"
           )

    refute has_element?(ctx.view, "a.track-plan-chip")

    assert has_element?(
             ctx.view,
             ".track-plan-toggle[aria-expanded=false][title='#{plan.title}']",
             "Plan: #{plan.title}"
           )

    assert has_element?(ctx.view, ".track-plan-toggle", "1 item")
    assert has_element?(ctx.view, ".track-plan-summary", "All plan items done")
  end

  test "closed, blocked and ready items retain their distinct labels", ctx do
    items =
      Enum.with_index([:closed_without_merge, :blocked, :ready], fn status, i ->
        %{
          id: "status-#{i}",
          title: "Status #{i}",
          position: i,
          status: status,
          status_available: false,
          pull: nil,
          brief: "Brief",
          acceptance: "",
          notes: []
        }
      end)

    expect(Ravix.Plans, :track_summary, fn _, _ ->
      {:ok, %{items: items, plan: nil, progress: Progress.summarize(items)}}
    end)

    send(ctx.view.pid, :refresh_plan_items)
    settle(ctx.view)
    ctx.view |> element(".track-plan-toggle") |> render_click()

    for label <- ["Closed without merge", "Blocked", "Unassigned"],
        do: assert(has_element?(ctx.view, ".plan-status", label))

    ctx.view |> element("#assigned-item-status-1 .track-plan-item-title") |> render_click()
    assert has_element?(ctx.view, ".track-plan-detail", "PR status is temporarily unavailable")
  end

  test "a delayed summary cannot expose plan metadata after project membership is revoked", ctx do
    {:ok, plan} =
      Ravix.Plans.create(ctx.user, ctx.project.id, %{
        "title" => "Member-only plan",
        "items" => [%{"id" => "delayed", "title" => "Assigned work"}]
      })

    Repo.get!(Ravix.Plans.Item, "delayed")
    |> Ecto.Changeset.change(track_id: ctx.track.id)
    |> Repo.update!()

    member = insert_user()
    membership = insert_project_member(ctx.project, member)
    insert_track_member(ctx.track, member)

    {:ok, parent, _} =
      live(log_in_user(build_conn(), member), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    settle(view)
    assert has_element?(view, ".track-plan-summary .track-plan-title", plan.title)
    {:ok, summary} = Ravix.Plans.track_summary(member, ctx.track.id)
    owner = self()

    expect(Ravix.Plans, :track_summary, fn _, _ ->
      send(owner, {:reading_plan, self()})

      receive do
        :finish -> {:ok, summary}
      end
    end)

    send(view.pid, :refresh_plan_items)
    assert_receive {:reading_plan, task}, 5_000
    Repo.delete!(membership)
    send(task, :finish)
    settle(view)
    refute render(view) =~ plan.title
    refute has_element?(view, ".track-plan-items a")
    view |> element(".track-plan-toggle") |> render_click()
    assert has_element?(view, ".track-plan-item-title", "Assigned work")
  end

  test "a track guest reads assigned material and notes without plan or sibling metadata", ctx do
    {:ok, plan} =
      Ravix.Plans.create(ctx.user, ctx.project.id, %{
        "title" => "Private project plan",
        "summary" => "Private rationale",
        "items" => [
          %{"id" => "allowed", "title" => "Allowed work", "brief" => "Implement the endpoint"},
          %{"id" => "hidden", "title" => "Hidden sibling"}
        ]
      })

    Repo.get!(Ravix.Plans.Item, "allowed")
    |> Ecto.Changeset.change(track_id: ctx.track.id)
    |> Repo.update!()

    guest = insert_user()
    insert_track_member(ctx.track, guest)

    {:ok, parent, _} =
      live(log_in_user(build_conn(), guest), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    settle(view)
    assert has_element?(view, ".track-plan-toggle[aria-expanded=false]", "Plan items · 1 item")
    # Named in full even when the compact header draws only the count.
    assert has_element?(view, ".track-plan-toggle[aria-label='Plan items · 1 item']")
    assert has_element?(view, ".track-plan-summary", "0 of 1 done")
    refute has_element?(view, ".track-plan-items a")
    view |> element(".track-plan-toggle") |> render_click()
    assert has_element?(view, ".track-plan-item-title", "Allowed work")
    assert has_element?(view, ".plan-status", "In progress")
    view |> element(".track-plan-item-title") |> render_click()
    assert has_element?(view, ".track-plan-detail", "Implement the endpoint")
    refute render(view) =~ plan.title
    refute render(view) =~ "Private rationale"
    refute render(view) =~ "Hidden sibling"
    view |> form("#track-note-allowed", %{body: "Verified endpoint"}) |> render_submit()
    settle(view)
    assert has_element?(view, "li", "Verified endpoint")
    Repo.delete_all(Ravix.Tracks.TrackMember)
    view |> form("#track-note-allowed", %{body: "revoked"}) |> render_submit()
    refute has_element?(view, "#track-note-allowed")
  end

  defp changes_fixture(truncated \\ false) do
    patch = File.read!("test/fixtures/diff/files.patch")

    %Diff{
      path: "/",
      repo_root: "/",
      diff: patch,
      truncated: truncated,
      changes: Diff.summarize(patch),
      files: Diff.parse(patch, truncated)
    }
  end

  test "changes list filters, opens escaped numbered hunks and keeps selection on refresh", ctx do
    expect(Tracks, :diff, 2, fn _, _ -> {:ok, changes_fixture(true)} end)
    render_click(ctx.view, "panel", %{name: "changes"})
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, ".change-file", "space name.txt")
    assert has_element?(ctx.view, ".changes-panel", "Diff is truncated.")
    ctx.view |> form(".changes-panel form", %{filter: "space"}) |> render_change()
    refute has_element?(ctx.view, ".change-file", "added.txt")
    ctx.view |> element(".change-file", "space name.txt") |> render_click()
    assert has_element?(ctx.view, ".diff-line.diff-add code", "<script>alert(1)</script>")
    refute has_element?(ctx.view, ".file-diff script")
    assert has_element?(ctx.view, ".diff-number[aria-hidden=true]", "2")
    assert has_element?(ctx.view, ".diff-add .sr-only", "Added line 2:")
    assert has_element?(ctx.view, ".diff-del .sr-only", "Removed line 2:")
    assert has_element?(ctx.view, ".changes-panel", "Partial file")
    render_click(ctx.view, "refresh-panel")
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, ".file-diff")
    ctx.view |> element("button", "All changed files") |> render_click()
    assert has_element?(ctx.view, "#diff-filter[value=space]")
    render_change(ctx.view, "filter-diff", %{filter: "missing"})
    assert has_element?(ctx.view, ".changes-panel", "No matching files")
  end

  for state <- [:open, :closed, :merged] do
    test "Checks identifies a #{state} pull request and links to GitHub", ctx do
      report = checks_fixture(unquote(state))

      expect(Tracks, :checks, fn user, id ->
        assert {user.id, id} == {ctx.user.id, ctx.track.id}
        {:ok, report}
      end)

      render_click(ctx.view, "panel", %{name: "checks"})
      render_async(ctx.view)

      assert has_element?(
               ctx.view,
               ".pull-state.chip",
               unquote(state |> Atom.to_string() |> String.capitalize())
             )

      assert has_element?(
               ctx.view,
               "a[href='https://github.com/acme/repo/pull/209']",
               "View on GitHub"
             )

      refute has_element?(ctx.view, "button[phx-value-name='pull']")
    end
  end

  test "Checks without a pull request retains the creation action", ctx do
    expect(Tracks, :checks, fn _, _ -> {:ok, %{checks_fixture(:open) | pull: nil}} end)
    render_click(ctx.view, "panel", %{name: "checks"})
    render_async(ctx.view)
    refute has_element?(ctx.view, ".pull-state")
    ctx.view |> element("button[phx-value-name='pull']", "Create pull request") |> render_click()
    assert has_element?(ctx.view, "#pull-dialog")
  end

  describe "the Checks tab's Git status" do
    defp git(uncommitted, unpushed, opts \\ []) do
      %Ravix.Tracks.Git.Status{
        uncommitted: uncommitted,
        unpushed: unpushed,
        upstream?: Keyword.get(opts, :upstream?, true),
        branch: Keyword.get(opts, :branch, "ravix/track")
      }
    end

    defp open_checks(ctx, status) do
      stub(Tracks, :checks, fn _, _ -> {:ok, %{checks_fixture(:open) | pull: nil}} end)

      expect(Tracks, :git_status, fn user, id ->
        assert {user.id, id} == {ctx.user.id, ctx.track.id}
        status
      end)

      render_click(ctx.view, "panel", %{name: "checks"})
      render_async(ctx.view)
    end

    test "shows the machine's uncommitted and unpushed counts beside the pull request", ctx do
      open_checks(ctx, {:ok, git(3, 1, upstream?: false)})

      assert has_element?(ctx.view, "#git-status .git-branch", "ravix/track")
      assert has_element?(ctx.view, "#git-uncommitted .chip.warn", "3")
      assert has_element?(ctx.view, "#git-uncommitted", "3 uncommitted changes")
      assert has_element?(ctx.view, "#git-uncommitted button", "Commit and push")
      assert has_element?(ctx.view, "#git-unpushed", "1 unpushed commit")
      assert has_element?(ctx.view, "#git-unpushed", "branch not on GitHub yet")
      assert has_element?(ctx.view, "#git-unpushed button", "Push")
      assert has_element?(ctx.view, "#git-pull", "No pull request")
      assert has_element?(ctx.view, "#git-pull button", "Create pull request")
    end

    test "a clean, pushed worktree offers nothing to do and links its pull request", ctx do
      stub(Tracks, :checks, fn _, _ -> {:ok, checks_fixture(:open)} end)
      expect(Tracks, :git_status, fn _, _ -> {:ok, git(0, 0)} end)
      render_click(ctx.view, "panel", %{name: "checks"})
      render_async(ctx.view)

      assert has_element?(ctx.view, "#git-uncommitted .chip.ok", "0")
      assert has_element?(ctx.view, "#git-uncommitted", "No uncommitted changes")
      assert has_element?(ctx.view, "#git-unpushed", "No unpushed commits")
      refute has_element?(ctx.view, "#git-commit")
      refute has_element?(ctx.view, "#git-push")

      assert has_element?(
               ctx.view,
               "#git-pull a[href='https://github.com/acme/repo/pull/209']",
               "Pull request #209"
             )
    end

    test "a machine that cannot be read says so and still shows the pull request row", ctx do
      open_checks(ctx, {:error, :machine_asleep})
      assert has_element?(ctx.view, "#git-status-error[role=alert]", "machine is asleep")
      refute has_element?(ctx.view, "#git-uncommitted")
      assert has_element?(ctx.view, "#git-pull button", "Create pull request")
    end

    test "commit and push opens on the track's title, commits the edited message and re-reads",
         ctx do
      open_checks(ctx, {:ok, git(2, 0)})
      ctx.view |> element("#git-commit") |> render_click()
      assert has_element?(ctx.view, "#commit-dialog textarea#commit-message", ctx.track.title)
      test_pid = self()

      expect(Tracks, :commit_and_push, fn user, id, message ->
        send(test_pid, {:committing, self()})
        receive do: (:finish -> :ok)
        assert {user.id, id, message} == {ctx.user.id, ctx.track.id, "Fix the login redirect"}
        :ok
      end)

      expect(Tracks, :git_status, fn _, _ -> {:ok, git(0, 0)} end)

      ctx.view
      |> form("#commit-form", %{message: "Fix the login redirect"})
      |> render_submit()

      assert_receive {:committing, worker}
      assert has_element?(ctx.view, "#git-writing", "Committing and pushing…")
      assert has_element?(ctx.view, "#commit-form button[disabled]")
      # A second press while the first is out is dropped, not queued.
      render_hook(ctx.view, "push", %{})
      send(worker, :finish)

      assert toasted(ctx) =~ "Committed and pushed."
      refute has_element?(ctx.view, "#commit-dialog")
      refute has_element?(ctx.view, "#git-writing")
      assert has_element?(ctx.view, "#git-uncommitted", "No uncommitted changes")
    end

    test "a refused commit keeps the message and says what refused it", ctx do
      open_checks(ctx, {:ok, git(1, 0)})
      ctx.view |> element("#git-commit") |> render_click()

      expect(Tracks, :commit_and_push, fn _, _, _ ->
        {:error,
         {:conflict, "commit_failed",
          "The commit was refused, so nothing was pushed. A commit hook may have failed.\n\nlint: 2 errors"}}
      end)

      expect(Tracks, :git_status, fn _, _ -> {:ok, git(1, 0)} end)
      ctx.view |> form("#commit-form", %{message: "WIP: my words"}) |> render_submit()
      render_async(ctx.view)

      assert has_element?(ctx.view, "#commit-failure[role=alert]", "lint: 2 errors")
      assert has_element?(ctx.view, "#commit-dialog textarea#commit-message", "WIP: my words")
      assert has_element?(ctx.view, "#git-failure[role=alert]", "commit was refused")
      refute has_element?(ctx.view, "#commit-form button[disabled]")
    end

    test "a rejected push is surfaced in the Git status block", ctx do
      open_checks(ctx, {:ok, git(0, 2)})

      expect(Tracks, :push, fn user, id ->
        assert {user.id, id} == {ctx.user.id, ctx.track.id}

        {:error,
         {:conflict, "push_rejected",
          "The push was rejected: the remote branch has commits this one does not."}}
      end)

      expect(Tracks, :git_status, fn _, _ -> {:ok, git(0, 2)} end)
      ctx.view |> element("#git-push") |> render_click()
      render_async(ctx.view)

      assert has_element?(ctx.view, "#git-failure[role=alert]", "The push was rejected")
      assert has_element?(ctx.view, "#git-unpushed", "2 unpushed commits")
      refute has_element?(ctx.view, "#git-push[disabled]")
    end

    test "a crashed write is reported rather than left spinning", ctx do
      open_checks(ctx, {:ok, git(0, 1)})
      expect(Tracks, :push, fn _, _ -> exit(:boom) end)
      expect(Tracks, :git_status, fn _, _ -> {:ok, git(0, 1)} end)
      ctx.view |> element("#git-push") |> render_click()
      render_async(ctx.view)

      assert has_element?(ctx.view, "#git-failure[role=alert]")
      refute has_element?(ctx.view, "#git-writing")
    end

    for event <- ["commit-push", "push"] do
      @git_event event
      test "a revoked session cannot #{event}", ctx do
        reject(Tracks, :commit_and_push, 3)
        reject(Tracks, :push, 2)
        token = Plug.Conn.get_session(ctx.conn, :session_token)
        Repo.delete!(Repo.get_by!(Session, token_hash: Ravix.Crypto.sha256(token)))

        :sys.replace_state(ctx.view.pid, fn state ->
          update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
        end)

        assert {:error, {:redirect, %{to: "/login"}}} =
                 render_hook(ctx.view, @git_event, %{message: "sneaky"})
      end
    end

    test "a member removed from the track cannot commit", ctx do
      member = insert_user()
      membership = insert_track_member(ctx.track, member)

      {:ok, parent, _} =
        live(log_in_user(build_conn(), member), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

      view = find_live_child(parent, "track-host")
      settle(view)
      reject(Tracks, :commit_and_push, 3)
      Repo.delete!(membership)

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns.track_guard, &%{&1 | stale?: true})
      end)

      assert {:error, {:redirect, %{to: "/"}}} =
               render_hook(view, "commit-push", %{message: "after removal"})
    end

    test "a session revoked mid-push does not render the push's answer", ctx do
      view = ctx.view
      stub(Tracks, :checks, fn _, _ -> {:ok, checks_fixture(:open)} end)
      stub(Tracks, :git_status, fn _, _ -> {:ok, git(0, 1)} end)
      render_click(view, "panel", %{name: "checks"})
      render_async(view)
      test_pid = self()

      expect(Tracks, :push, fn _, _ ->
        send(test_pid, {:pushing, self()})
        receive do: (:finish -> :ok)
        {:error, {:conflict, "push_failed", "revoked secret"}}
      end)

      view |> element("#git-push") |> render_click()
      assert_receive {:pushing, worker}
      token = Plug.Conn.get_session(ctx.conn, :session_token)
      Ravix.Accounts.end_session(Ravix.Crypto.sha256(token))
      send(worker, :finish)
      assert_redirect(ctx.parent, "/login", 1_000)
    end
  end

  for state <- [:merged, :closed, :open, :missing, :unavailable] do
    test "empty Changes handles #{state} PR state without visiting Checks first", ctx do
      diff = %{changes_fixture() | diff: "", changes: [], files: []}
      stub(Tracks, :diff, fn _, _ -> {:ok, diff} end)

      expect(Tracks, :checks, fn user, id ->
        assert {user.id, id} == {ctx.user.id, ctx.track.id}

        case unquote(state) do
          :unavailable -> {:error, :github_unavailable}
          :missing -> {:ok, %{checks_fixture(:open) | pull: nil}}
          state -> {:ok, checks_fixture(state)}
        end
      end)

      render_click(ctx.view, "panel", %{name: "changes"})
      render_async(ctx.view)

      if unquote(state) == :merged do
        assert has_element?(ctx.view, ".changes-panel .empty h3", "Branch merged")
        assert has_element?(ctx.view, ".changes-panel", "This branch was merged")
        refute has_element?(ctx.view, ".changes-panel", "No changes yet")
        expect(Tracks, :checks, fn _, _ -> {:ok, checks_fixture(:open)} end)
        render_click(ctx.view, "refresh-panel")
        render_async(ctx.view)
      end

      assert has_element?(ctx.view, ".changes-panel .empty h3", "No changes yet")
    end
  end

  test "nonempty Changes does not fetch PR state", ctx do
    expect(Tracks, :diff, fn _, _ -> {:ok, changes_fixture()} end)
    reject(Tracks, :checks, 2)
    render_click(ctx.view, "panel", %{name: "changes"})
    render_async(ctx.view)
    assert has_element?(ctx.view, ".changes-summary")
    refute has_element?(ctx.view, ".changes-panel", "Branch merged")
  end

  test "large diffs require an explicit show action and empty diffs retain their message", ctx do
    patch =
      "diff --git a/large b/large\n@@ -0,0 +1,1001 @@\n" <> String.duplicate("+line\n", 1001)

    diff = %{
      changes_fixture()
      | diff: patch,
        changes: Diff.summarize(patch),
        files: Diff.parse(patch)
    }

    expect(Tracks, :diff, fn _, _ -> {:ok, diff} end)
    render_click(ctx.view, "panel", %{name: "changes"})
    render_async(ctx.view, 1_000)
    render_click(ctx.view, "select-diff", %{path: "large"})
    refute has_element?(ctx.view, ".file-diff")
    ctx.view |> element("button", "Show anyway") |> render_click()
    assert has_element?(ctx.view, ".file-diff")
    expect(Tracks, :diff, fn _, _ -> {:ok, %{diff | diff: "", changes: [], files: []}} end)
    render_click(ctx.view, "refresh-panel")
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, ".changes-panel .empty h3", "No changes yet")
    # Nothing to filter and nothing to count: no search box, no "0 changed files".
    refute has_element?(ctx.view, "#diff-filter")
    refute has_element?(ctx.view, ".changes-summary")
    refute has_element?(ctx.view, "nav[aria-label='Inspector panels'] .tab-count")
  end

  test "the Changes tab counts its files once a read has, and each file says how much", ctx do
    tab = "nav[aria-label='Inspector panels'] button[phx-value-name=changes]"
    # Nothing has read a diff yet, and nothing reads one to draw a badge.
    refute has_element?(ctx.view, "#{tab} .tab-count")

    expect(Tracks, :diff, fn _, _ -> {:ok, changes_fixture()} end)
    render_click(ctx.view, "panel", %{name: "changes"})
    render_async(ctx.view, 1_000)

    assert has_element?(ctx.view, "#{tab} .tab-count[aria-hidden=true]", "8")
    assert has_element?(ctx.view, "#{tab} .sr-only", ", 8 changed files")
    assert has_element?(ctx.view, ".changes-summary", "8 changed files")
    assert has_element?(ctx.view, ".changes-summary .diff-add", "+4")
    assert has_element?(ctx.view, ".changes-summary .diff-del", "−4")

    added = ".change-file[phx-value-path='added.txt']"
    assert has_element?(ctx.view, "#{added} .change-status.change-added[title=Added]", "A")
    assert has_element?(ctx.view, "#{added} .sr-only", "Added:")
    assert has_element?(ctx.view, "#{added} .change-counts .diff-add", "+1")
    assert has_element?(ctx.view, "#{added} .change-counts .diff-del", "−0")
    deleted = ".change-file[phx-value-path='deleted.txt']"
    assert has_element?(ctx.view, "#{deleted} .change-status.change-deleted", "D")
    # A binary file has no lines to count, and says what it is instead of +0 −0.
    binary = ".change-file[phx-value-path='binary.dat']"
    assert has_element?(ctx.view, "#{binary} .change-tag", "Binary")
    refute has_element?(ctx.view, "#{binary} .change-counts")

    # The count belongs to the tab, not to the list: it stays while another shows.
    render_click(ctx.view, "panel", %{name: "files"})
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, "#{tab} .tab-count", "8")

    # A turn ending out of sight may have changed the worktree. The count is
    # forgotten rather than kept wrong, and nothing is read to replace it:
    # `expect/3` above allowed exactly one diff.
    settled = %{"id" => 9, "turn_id" => "t", "kind" => "stage", "stage" => "turn"}
    send(ctx.view.pid, {:transcript, ctx.track.id, Map.put(settled, "state", "completed")})
    render_async(drawn(ctx.view))
    refute has_element?(ctx.view, "#{tab} .tab-count")
    assert has_element?(ctx.view, ".file-explorer")
  end

  test "a truncated diff's count is a floor, and says so", ctx do
    expect(Tracks, :diff, fn _, _ -> {:ok, changes_fixture(true)} end)
    render_click(ctx.view, "panel", %{name: "changes"})
    render_async(ctx.view, 1_000)
    tab = "nav[aria-label='Inspector panels'] button[phx-value-name=changes]"
    assert has_element?(ctx.view, "#{tab} .tab-count", "8+")
    assert has_element?(ctx.view, "#{tab} .sr-only", "8 changed files or more")
  end

  test "a turn ending re-reads the Changes list in place, and only a turn ending", ctx do
    test_pid = self()
    patch = "diff --git a/one.txt b/one.txt\n@@ -1 +1,2 @@\n one\n+two\n"

    expect(Tracks, :diff, fn _, _ -> {:ok, changes_fixture()} end)
    render_click(ctx.view, "panel", %{name: "changes"})
    render_async(ctx.view, 1_000)
    ctx.view |> element(".change-file", "space name.txt") |> render_click()

    # Output streaming in is not a turn ending, and reads nothing.
    output = %{"id" => 1, "turn_id" => "t", "kind" => "output", "stream" => "acp", "data" => "Hi"}
    send(ctx.view.pid, {:transcript, ctx.track.id, output})
    render(drawn(ctx.view))

    # The re-read waits for the test, so what the panel shows while it is out
    # can be asserted rather than raced.
    expect(Tracks, :diff, fn _, _ ->
      send(test_pid, {:reading_diff, self()})
      assert_receive :go, 5_000

      {:ok,
       %Diff{
         path: "/",
         repo_root: "/",
         diff: patch,
         truncated: false,
         changes: Diff.summarize(patch),
         files: Diff.parse(patch)
       }}
    end)

    settled = %{"id" => 2, "turn_id" => "t", "kind" => "stage", "stage" => "turn"}
    send(ctx.view.pid, {:transcript, ctx.track.id, Map.put(settled, "state", "completed")})
    assert_receive {:reading_diff, reader}, 5_000

    # The diff somebody was reading stays on screen; the refresh turns instead
    # of the panel blanking into "Loading inspector…".
    assert has_element?(ctx.view, ".file-diff")
    assert has_element?(ctx.view, "button.panel-refresh.busy[disabled]")
    refute has_element?(ctx.view, ".workspace-panel .loading-status")

    send(reader, :go)
    render_async(ctx.view, 1_000)
    refute has_element?(ctx.view, "button.panel-refresh.busy")
    # The file that was open is no longer in the diff, so the list is showing.
    refute has_element?(ctx.view, ".file-diff")
    assert has_element?(ctx.view, ".changes-summary", "1 changed file")
    assert has_element?(ctx.view, ".change-file[phx-value-path='one.txt']")
    tab = "nav[aria-label='Inspector panels'] button[phx-value-name=changes]"
    assert has_element?(ctx.view, "#{tab} .tab-count", "1")
  end

  test "Refresh is an icon in the inspector's tab bar and reads the tab again", ctx do
    assert has_element?(
             ctx.view,
             "#inspector-toggle[phx-hook=PanelToggle][aria-controls=inspector][aria-expanded=true]",
             "Hide inspector"
           )

    assert has_element?(ctx.view, "#inspector-toggle .label-show", "Show inspector")

    button = "nav[aria-label='Inspector panels'] button.panel-refresh[aria-label=Refresh]"
    assert has_element?(ctx.view, "#{button} svg")
    refute has_element?(ctx.view, ".workspace-panel button", "Refresh")

    expect(Tracks, :files, fn _, _, nil ->
      {:ok,
       %Files.Listing{
         path: ctx.track.workdir,
         truncated: false,
         entries: [%Files.Entry{name: "fresh.txt", type: "file", size: 1}]
       }}
    end)

    ctx.view |> element(button) |> render_click()
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, ".file-explorer", "fresh.txt")
  end

  test "selecting a diff respects session revocation", ctx do
    expect(Tracks, :diff, fn _, _ -> {:ok, changes_fixture()} end)
    render_click(ctx.view, "panel", %{name: "changes"})
    render_async(ctx.view, 1_000)
    token = Plug.Conn.get_session(ctx.conn, :session_token)
    Repo.get!(Session, Ravix.Crypto.sha256(token)) |> Repo.delete!()

    :sys.replace_state(ctx.view.pid, fn state ->
      update_in(
        state.socket.assigns.session_guard,
        &%{&1 | verified_at_ms: &1.verified_at_ms - Guard.ttl_ms() - 1}
      )
    end)

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_click(ctx.view, "select-diff", %{path: "space name.txt"})
  end

  test "diff selection only opens loaded paths and presents metadata", ctx do
    expect(Tracks, :diff, fn _, _ -> {:ok, changes_fixture()} end)
    render_click(ctx.view, "panel", %{name: "changes"})
    render_async(ctx.view, 1_000)
    render_click(ctx.view, "select-diff", %{path: "../../private"})
    refute has_element?(ctx.view, ".file-diff")
    assert has_element?(ctx.view, ".change-file")

    for {path, text} <- [
          {"binary.dat", "Binary files differ"},
          {"mode.sh", "new mode 100755"},
          {"new name.txt", "old name.txt →"},
          {"nonewline.txt", "No newline at end of file"}
        ] do
      render_click(ctx.view, "select-diff", %{path: path})
      assert has_element?(ctx.view, ".changes-panel", text)
    end
  end

  test "diff selection refuses a removed track member even if the notice was lost", ctx do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project, conversation_id: "shared-diff")
    People.Store.add_member(track.id, ctx.user.id, owner.id)
    {:ok, parent, _} = live(ctx.conn, "/p/#{project.id}/t/#{track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    expect(Tracks, :diff, fn _, _ -> {:ok, changes_fixture()} end)
    render_click(view, "panel", %{name: "changes"})
    render_async(view, 1_000)
    Repo.get_by!(TrackMember, track_id: track.id, user_id: ctx.user.id) |> Repo.delete!()

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.track_guard, &%{&1 | stale?: true})
    end)

    assert {:error, {:redirect, %{to: "/"}}} =
             render_click(view, "select-diff", %{path: "space name.txt"})
  end

  test "Send keeps its icon and accessible name through every track state", ctx do
    for status <- [:opening, :running, :ready, :failed],
        conversation_id <- [nil, "live-conversation"] do
      stub(Tracks, :get, fn _, _, _ ->
        track = %{
          Tracks.present(ctx.track, role: :owner)
          | status: status,
            conversation_id: conversation_id
        }

        {:ok,
         %{
           track: track,
           header: blank_header(),
           starters: [],
           models: [],
           threads: thread_options(ctx.track.id)
         }}
      end)

      send(ctx.view.pid, {:hub, Event.new(:tracks, ctx.project.id, track_id: ctx.track.id)})
      settle(ctx.view)

      button = "#composer-form button[aria-label='Send']"
      assert has_element?(ctx.view, button <> "[type='submit'][title='Send']")
      refute has_element?(ctx.view, button, "Send")
      assert has_element?(ctx.view, button <> " svg[width='16'][height='16'] path")
      refute has_element?(ctx.view, button <> "[phx-disable-with]")
      assert has_element?(ctx.view, button <> "[disabled]") == is_nil(conversation_id)

      assert has_element?(ctx.view, "#composer-form button", "Stop") ==
               status in [:opening, :running]

      assert has_element?(ctx.view, "#composer-form button", "Wake / retry") ==
               status in [:opening, :failed]

      assert has_element?(ctx.view, "#composer-form button[aria-label='Choose images'] svg")
      refute has_element?(ctx.view, "#composer-form", "to send")

      assert has_element?(
               ctx.view,
               ".composer-model[title='Claude Code · Claude Sonnet 5']",
               "Claude Sonnet 5"
             )
    end
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

  test "a first prompt's title reaches the header, the thread tab and the rail live", ctx do
    # A track still carrying its branch as its name, with a second thread so
    # the tabs are drawn.
    Repo.update!(Ecto.Changeset.change(ctx.track, title: ctx.track.branch))

    {:ok, _} =
      Tracks.Store.create_thread(%{
        track_id: ctx.track.id,
        conversation_id: "live-second",
        title: "Second"
      })

    {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    render_async(parent)
    assert has_element?(view, "#thread-tab-#{ctx.track.id}", "Default")

    request_id = "first-prompt-#{System.unique_integer([:positive])}"

    {:ok, _} =
      PromptQueue.Store.enqueue(
        ctx.track.id,
        ctx.user.id,
        ctx.user.login,
        request_id,
        %PromptQueue.Body{prompt: "Could you pull the latest main?", images: []}
      )

    # What the background task runs, here in the test's process; the page
    # hears it on the project's hub, as every other page on the project does.
    assert :ok =
             Tracks.Titling.from_prompt(
               ctx.track.id,
               ctx.track.id,
               request_id,
               "Could you pull the latest main?"
             )

    settle(view)
    assert has_element?(view, "header button", "Pull Latest Main")
    assert has_element?(view, "#thread-tab-#{ctx.track.id}", "Pull Latest Main")
    # The branch is still shown beside the new name.
    assert render(view) =~ ctx.track.branch
    assert render_async(parent) =~ "Pull Latest Main"
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
    expect(Tracks, :retry, fn user, id, _thread_id ->
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

  test "folders expand in place, preserve the file, and collapse independently", ctx do
    root = ctx.track.workdir

    stub(Tracks, :files, fn _, _, path ->
      entries =
        if path in [nil, root] do
          [{"src", "directory"}, {"assets", "directory"}, {"README.md", "file"}]
        else
          [{"app.ex", "file"}, {"empty", "directory"}]
        end

      {:ok,
       %Files.Listing{
         path: path || root,
         truncated: false,
         entries:
           Enum.map(entries, fn {name, type} -> %Files.Entry{name: name, type: type, size: 0} end)
       }}
    end)

    render_click(ctx.view, "refresh-panel")
    render_async(ctx.view)

    stub(Tracks, :file, fn _, _, path ->
      {:ok,
       %Files.Content{
         path: path,
         encoding: "utf-8",
         content: "hello explorer",
         size: 14,
         truncated: false
       }}
    end)

    ctx.view |> element("button.workspace-file", "README.md") |> render_click()
    render_async(ctx.view)
    ctx.view |> element("button.workspace-file", "src") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, ".file-list .file-list button", "app.ex")
    assert has_element?(ctx.view, "button.workspace-file", "assets")
    assert has_element?(ctx.view, "button[aria-expanded=true]", "src")
    assert has_element?(ctx.view, "button[aria-current=true]", "README.md")
    assert has_element?(ctx.view, "pre", "hello explorer")
    ctx.view |> element("button.workspace-file", "src") |> render_click()
    refute has_element?(ctx.view, "button.workspace-file", "app.ex")
    assert has_element?(ctx.view, "button[aria-expanded=false]", "src")
    assert has_element?(ctx.view, "pre", "hello explorer")
  end

  test "listing renders before blocked metadata exec and is enriched afterward", ctx do
    owner = self()

    stub(Tracks, :files, fn _, _, _ ->
      {:ok,
       %Files.Listing{
         path: ctx.track.workdir,
         truncated: false,
         entries: [
           %Files.Entry{name: "_build", type: "directory", size: 0},
           %Files.Entry{name: "src", type: "directory", size: 0}
         ]
       }}
    end)

    expect(Terminal, :status, fn _, _, [passive: true] -> {:ok, %{available: true}} end)

    expect(Terminal, :exec, fn _, _, _ ->
      send(owner, {:metadata_exec, self()})

      receive do
        :finish ->
          {:ok,
           %{code: 0, stdout: ~s({"ignore_available":true,"entries":{"_build":{"ignored":true}}})}}
      end
    end)

    render_click(ctx.view, "refresh-panel")
    assert_receive {:metadata_exec, worker}
    assert has_element?(ctx.view, ".file-name", "_build")
    assert has_element?(ctx.view, ".file-name", "src")
    assert has_element?(ctx.view, "button[phx-click='toggle-ignored']")
    refute has_element?(ctx.view, ".file-note", "Git ignore filtering is unavailable")
    send(worker, :finish)
    render_async(ctx.view, 1_000)
    refute has_element?(ctx.view, ".file-note", "Git ignore filtering is unavailable")
    refute has_element?(ctx.view, ".file-name", "_build")
    ctx.view |> element("button[phx-click='toggle-ignored']") |> render_click()
    assert has_element?(ctx.view, ".file-name", "_build")
  end

  test "unavailable filtering appears once at the root only after metadata finishes", ctx do
    owner = self()
    notice = "Git ignore filtering is unavailable for this directory."

    stub(Tracks, :file_metadata, fn _, _, listing ->
      if listing.path == ctx.track.workdir do
        send(owner, {:metadata_pending, self()})
        receive do: (:finish -> {:ok, listing})
      else
        {:ok, listing}
      end
    end)

    render_click(ctx.view, "refresh-panel")
    assert_receive {:metadata_pending, worker}
    assert has_element?(ctx.view, ".file-name", "src")
    refute has_element?(ctx.view, ".file-note", notice)
    send(worker, :finish)
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, ".file-explorer > .file-note", notice)
    assert has_element?(ctx.view, "button[phx-click='toggle-ignored']")

    for path <- ["src", "src/src"] do
      ctx.view
      |> element("button[phx-value-path='#{ctx.track.workdir}/#{path}']")
      |> render_click()

      render_async(ctx.view, 1_000)
      render_async(ctx.view, 1_000)
      assert has_element?(ctx.view, ".file-explorer > .file-note", notice)
      refute has_element?(ctx.view, ".file-list .file-note", notice)
    end
  end

  test "internal directory links expand their targets and ancestor links cannot recurse", ctx do
    target = Path.join(ctx.track.workdir, ".agents/skills")

    stub(Tracks, :files, fn _, _, path ->
      entries =
        if path == target do
          [
            %Files.Entry{name: "guide.md", type: "file", size: 12},
            %Files.Entry{
              name: "back",
              type: "symlink",
              size: 0,
              target: "../..",
              directory_target: ctx.track.workdir
            }
          ]
        else
          [
            %Files.Entry{
              name: "skills",
              type: "symlink",
              size: 0,
              target: ".agents/skills",
              directory_target: target
            }
          ]
        end

      {:ok, %Files.Listing{path: path || ctx.track.workdir, entries: entries, truncated: false}}
    end)

    render_click(ctx.view, "refresh-panel")
    render_async(ctx.view, 1_000)
    button = "button[phx-click='directory'][phx-value-path='#{target}']:not([disabled])"
    assert has_element?(ctx.view, button, "skills")
    ctx.view |> element(button) |> render_click()
    render_async(ctx.view, 1_000)
    assert has_element?(ctx.view, ".file-name", "guide.md")
    assert has_element?(ctx.view, "button[disabled][aria-expanded=false]", "back")
    ctx.view |> element(button) |> render_click()
    refute has_element?(ctx.view, ".file-name", "guide.md")
  end

  test "a collapsed directory rejects its late metadata result", ctx do
    owner = self()

    expect(Tracks, :file_metadata, fn _, _, listing ->
      send(owner, {:metadata_reader, self()})

      receive do: (:finish ->
                     {:ok,
                      %{
                        listing
                        | entries: [
                            %Files.Entry{name: "late", type: "file", size: 0}
                          ]
                      }})
    end)

    ctx.view |> element("button.workspace-file", "src") |> render_click()
    assert_receive {:metadata_reader, reader}
    ctx.view |> element("button.workspace-file[aria-expanded=true]", "src") |> render_click()
    send(reader, :finish)
    render_async(ctx.view, 1_000)
    refute has_element?(ctx.view, ".file-name", "late")
    refute has_element?(ctx.view, ".file-list .file-list")
  end

  test "ignored entries are hidden throughout the tree and the toggle restores them", ctx do
    stub(Tracks, :files, fn _, _, path ->
      {:ok,
       %Files.Listing{
         path: path || ctx.track.workdir,
         truncated: false,
         ignore_available?: true,
         entries: [
           %Files.Entry{name: "src", type: "directory", size: 0},
           %Files.Entry{name: "_build", type: "directory", size: 0, ignored?: true},
           %Files.Entry{name: "skills", type: "symlink", size: 0, target: "../.agents/skills"}
         ]
       }}
    end)

    render_click(ctx.view, "refresh-panel")
    render_async(ctx.view)
    refute has_element?(ctx.view, ".file-name", "_build")
    assert has_element?(ctx.view, "button[disabled] .file-name", "skills → ../.agents/skills")
    ctx.view |> element("button[phx-value-path='#{ctx.track.workdir}/src']") |> render_click()
    render_async(ctx.view)
    refute has_element?(ctx.view, ".file-name", "_build")
    ctx.view |> element("button[phx-click='toggle-ignored']") |> render_click()
    assert has_element?(ctx.view, "button[aria-pressed='true']", "Show ignored files")
    assert has_element?(ctx.view, "button[phx-value-path='#{ctx.track.workdir}/_build']")
    assert has_element?(ctx.view, "button[phx-value-path='#{ctx.track.workdir}/src/_build']")
    ctx.view |> element("button[phx-click='toggle-ignored']") |> render_click()
    refute has_element?(ctx.view, ".file-name", "_build")

    assert has_element?(
             ctx.view,
             "button[phx-value-path='#{ctx.track.workdir}/src'][aria-expanded='true']"
           )
  end

  test "collapsed folders ignore late results and directory errors can be retried", ctx do
    owner = self()

    expect(Tracks, :files, fn _, _, path ->
      send(owner, {:directory_reader, self()})
      receive do: (:finish -> {:ok, %Files.Listing{path: path, entries: [], truncated: false}})
    end)

    ctx.view |> element("button.workspace-file", "src") |> render_click()
    assert_receive {:directory_reader, reader}
    assert has_element?(ctx.view, ".file-note[role=status]", "Loading")
    ctx.view |> element("button.workspace-file", "src") |> render_click()
    send(reader, :finish)
    render_async(ctx.view)
    refute has_element?(ctx.view, ".file-note[role=status], .file-note[role=alert]")
    refute has_element?(ctx.view, ".file-list .file-list")
    expect(Tracks, :files, fn _, _, _ -> {:error, {:unavailable, "Folder offline"}} end)
    ctx.view |> element("button.workspace-file", "src") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, ".file-note[role=alert]", "Folder offline")
    ctx.view |> element("button.workspace-file", "src") |> render_click()

    expect(Tracks, :files, fn _, _, path ->
      {:ok, %Files.Listing{path: path, entries: [], truncated: true}}
    end)

    ctx.view |> element("button.workspace-file", "src") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, ".file-note", "Empty directory")
    assert has_element?(ctx.view, ".file-note", "Directory listing is truncated")
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

  for {layout, label} <- [
        shared: "Shared project machine (used by all of this project's tracks)",
        dedicated: "This track's machine"
      ] do
    @layout layout
    @machine_label label
    test "#{layout} machine ownership is visible in the dock, terminal and Vitals", ctx do
      Repo.update!(
        Ecto.Changeset.change(ctx.track, sandbox_layout: @layout, opened_at: DateTime.utc_now())
      )

      stub(Terminal, :status, fn _, _, _ ->
        {:ok, %Terminal.Status{available: true, why: nil, cwd: ctx.track.workdir}}
      end)

      stub(Vitals, :report, fn _, _ ->
        {:ok, %Vitals.Report{available: false, why: :no_machine, readings: nil}}
      end)

      {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
      view = find_live_child(parent, "track-host")
      render_async(view)
      assert has_element?(view, "#track-machine-label", @machine_label)
      assert has_element?(view, "#track-machine-status", "Idle.")
      view |> element("button[phx-click=dock][phx-value-name=terminal]") |> render_click()
      assert has_element?(view, "#terminal-machine-label", @machine_label)
      view |> element("button[phx-click=dock][phx-value-name=vitals]") |> render_click()
      render_async(view)
      assert has_element?(view, "#vitals-machine-label", @machine_label)
      assert has_element?(view, ".dock-empty", "No machine is available yet.")
    end
  end

  for {reason, sentence} <- [
        no_machine: "No machine is available yet.",
        no_token:
          "Machine status is unavailable because the machine connection is not configured.",
        no_sprite: "Idle. The machine did not answer just now; your next message wakes it.",
        unreachable: "Idle. The machine did not answer just now; your next message wakes it.",
        error: "Machine status is unavailable. Try again later."
      ] do
    @status_reason reason
    @status_sentence sentence
    test "machine status explains #{@status_reason} in plain language", ctx do
      Repo.update!(Ecto.Changeset.change(ctx.track, opened_at: DateTime.utc_now()))

      stub(Terminal, :status, fn _, _, _ ->
        if @status_reason == :error,
          do: {:error, :not_found},
          else:
            {:ok, %Terminal.Status{available: false, why: @status_reason, cwd: ctx.track.workdir}}
      end)

      {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
      view = find_live_child(parent, "track-host")
      render_async(view)
      assert has_element?(view, "#track-machine-status", @status_sentence)
    end
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
    ctx.view |> element("button[phx-click=dock][phx-value-name=terminal]") |> render_click()
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

  test "the machine status says a shared track runs on the whole project's machine", ctx do
    stub(Ravix.Terminal, :status, fn _, _, _ ->
      {:ok, %Ravix.Terminal.Status{available: true, why: nil, cwd: ctx.track.workdir}}
    end)

    {:ok, parent, _} =
      live(log_in_user(build_conn(), ctx.user), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    settle(view)
    render_async(view, 1_000)

    assert has_element?(
             view,
             "#track-machine-label",
             "Shared project machine (used by all of this project's tracks)"
           )
  end

  test "Commands combines standalone execution in one clearly named dock tab", ctx do
    ctx.view
    |> element("button[phx-click=dock][phx-value-name=terminal]", "Commands")
    |> render_click()

    assert has_element?(ctx.view, "#machine-dock:not([hidden])")
    assert has_element?(ctx.view, "#track-terminal .dock-empty h3", "No commands yet")
    assert has_element?(ctx.view, "#track-terminal .dock-empty", "tests, builds and scripts")

    assert has_element?(
             ctx.view,
             "#track-terminal .dock-empty",
             "For an interactive shell, such as a console or a REPL, open a terminal with +."
           )

    assert has_element?(
             ctx.view,
             "#track-terminal .dock-empty",
             "For a process that keeps running"
           )

    refute has_element?(ctx.view, "button[phx-click=dock]", "Run")
    refute has_element?(ctx.view, "button[phx-click=dock]", "Terminal")
  end

  test "the Commands tab's empty state opens Previews, and output replaces it", ctx do
    stub(Previews, :status, fn _, _ -> {:ok, preview()} end)
    ctx.view |> element("button[phx-click=dock][phx-value-name=terminal]") |> render_click()

    # The button is the dock's, but the tab it opens is the page's: the push
    # carries no target, so it reaches `TrackLive` rather than the component.
    ctx.view |> element("#track-terminal .dock-empty button", "Open Preview") |> render_click()
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "nav[aria-label='Inspector panels'] button.selected",
             "Preview"
           )

    assert has_element?(ctx.view, "#preview-config-form")

    expect(Terminal, :exec, fn _, _, _ ->
      {:ok,
       %Terminal.Result{
         cwd: ctx.track.workdir,
         stdout: "ok",
         stderr: "",
         code: 0,
         timed_out: false,
         duration_ms: 1
       }}
    end)

    ctx.view |> element("#track-terminal") |> render_hook("exec", %{command: "mix test"})
    render_async(ctx.view)
    assert has_element?(ctx.view, "#track-terminal strong", "$ mix test")
    refute has_element?(ctx.view, "#track-terminal .dock-empty")

    # Clearing the scrollback is an empty terminal again, and says so.
    ctx.view |> element("button[phx-click=clear]") |> render_click()
    assert has_element?(ctx.view, "#track-terminal .dock-empty", "Open Preview")
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

  test "a file result from a replaced workspace is discarded", ctx do
    test_pid = self()

    expect(Tracks, :file, fn _, _, _ ->
      send(test_pid, {:file_waiting, self()})
      receive do: (:finish -> :ok)

      {:ok,
       %Files.Content{
         path: "secret.txt",
         content: "old file secret",
         encoding: "utf-8",
         truncated: false,
         size: 15
       }}
    end)

    render_click(ctx.view, "file", %{path: "secret.txt"})
    assert_receive {:file_waiting, worker}
    Repo.update!(Ecto.Changeset.change(ctx.track, sandbox_generation: 1))
    send(worker, :finish)
    html = render_async(ctx.view)
    refute html =~ "old file secret"
    assert html =~ "workspace changed"
  end

  test "a command result from a replaced workspace never enters the dock", ctx do
    test_pid = self()

    expect(Terminal, :exec, fn _, _, _ ->
      send(test_pid, {:command_waiting, self()})
      receive do: (:finish -> :ok)
      {:ok, %{cwd: ctx.track.workdir, stdout: "old disk secret", stderr: "", code: 0}}
    end)

    ctx.view |> element("#track-terminal") |> render_hook("exec", %{command: "cat secret"})
    assert_receive {:command_waiting, worker}
    Repo.update!(Ecto.Changeset.change(ctx.track, sandbox_generation: 1))
    send(worker, :finish)
    refute render_async(ctx.view) =~ "old disk secret"
    refute has_element?(ctx.view, ".term-command[disabled]")
  end

  test "a revoked session cannot receive an in-flight command result", ctx do
    {token, session} = insert_session(ctx.user)
    conn = Plug.Test.init_test_session(build_conn(), session_token: token)
    {:ok, parent, _} = live(conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    test_pid = self()

    expect(Terminal, :exec, fn _, _, _ ->
      send(test_pid, {:command_waiting, self()})
      receive do: (:finish -> :ok)
      {:ok, %{cwd: ctx.track.workdir, stdout: "revoked secret", stderr: "", code: 0}}
    end)

    view |> element("#track-terminal") |> render_hook("exec", %{command: "pwd"})
    assert_receive {:command_waiting, worker}
    Repo.delete!(session)
    send(worker, :finish)
    assert_redirect(parent, "/login", 1_000)
  end

  test "a membership revoked during a Vitals read cannot render its response", ctx do
    member = insert_user()
    membership = insert_track_member(ctx.track, member)

    {:ok, parent, _} =
      live(log_in_user(build_conn(), member), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    settle(view)
    test_pid = self()

    expect(Vitals, :report, fn _, _ ->
      send(test_pid, {:vitals_waiting, self()})
      receive do: (:finish -> :ok)
      {:ok, %Vitals.Report{available: true, why: nil, readings: Vitals.parse_vitals("nproc=123")}}
    end)

    view |> element("button[phx-click=dock][phx-value-name=vitals]") |> render_click()
    assert_receive {:vitals_waiting, worker}
    Repo.delete!(membership)
    send(worker, :finish)
    render_async(view)
    # Project IDs and signed session attributes can contain the fixture number.
    # The protected response is the stats panel, not arbitrary HTML bytes.
    refute has_element?(view, ".machine-stats")
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
    # The dock reads vitals under `start_async`; the readout exists once it lands.
    rendered = render_async(ctx.view)

    assert rendered =~ "Memory used"
    assert rendered =~ "32.0 MB"
    assert rendered =~ "12%"
    refute rendered =~ "33554432"
    assert has_element?(ctx.view, ~s(meter[aria-label="CPU in use"][value="0.12"]))
    # A reading the machine could not give is left out, not drawn as a blank
    # row: `mem_total_bytes` is nil and no "Memory total" appears.
    refute rendered =~ "Memory total"

    expect(Vitals, :report, fn _, _ ->
      {:ok, %Vitals.Report{available: false, why: :no_machine, readings: nil}}
    end)

    ctx.view |> element("button[phx-click=dock][phx-value-name=vitals]") |> render_click()
    render_async(ctx.view)
    # The reason is a sentence, not the atom `Vitals` answers with.
    assert has_element?(ctx.view, ".dock-empty h3", "No machine stats")
    assert has_element?(ctx.view, ".dock-empty", "No machine is available yet")
    refute render(ctx.view) =~ "no_machine"

    # Asking again is the empty state's action, and it is a real second read.
    expect(Vitals, :report, fn _, _ ->
      {:ok, %Vitals.Report{available: false, why: :unreachable, readings: nil}}
    end)

    ctx.view |> element(".dock-empty button", "Try again") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, ".dock-empty", "asleep or unreachable")

    # A server with no token cannot be retried into having one.
    expect(Vitals, :report, fn _, _ ->
      {:ok, %Vitals.Report{available: false, why: :no_token, readings: nil}}
    end)

    ctx.view |> element(".dock-empty button", "Try again") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, ".dock-empty", "machine connection is not configured")
    refute has_element?(ctx.view, ".dock-empty button", "Try again")

    # Reachable but with nothing legible to report is its own sentence.
    expect(Vitals, :report, fn _, _ ->
      {:ok, %Vitals.Report{available: true, why: nil, readings: nil}}
    end)

    ctx.view |> element("button[phx-click=dock][phx-value-name=vitals]") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, ".dock-empty", "reported no readings")
  end

  test "vitals that could not be read say so and offer another try", ctx do
    expect(Vitals, :report, fn _, _ -> {:error, :not_found} end)
    ctx.view |> element("button[phx-click=dock][phx-value-name=vitals]") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, ".dock-empty", "did not answer")
    assert has_element?(ctx.view, ".dock-empty button", "Try again")
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

  for {state, run?, restart?, stop?} <- [
        {:stopped, true, false, false},
        {:starting, false, true, true},
        {:ready, false, true, true},
        {:failed, true, false, true}
      ] do
    test "preview controls reflect #{state}", ctx do
      stub(Previews, :status, fn _, _ -> {:ok, %{preview() | state: unquote(state)}} end)
      render_click(ctx.view, "panel", %{name: "preview"})
      render_async(ctx.view)

      assert has_element?(
               ctx.view,
               "button.primary[phx-value-action='run']:not([disabled])",
               "Run"
             ) == unquote(run?)

      assert has_element?(ctx.view, "button[phx-value-action='restart-run']") == unquote(restart?)

      assert has_element?(ctx.view, "button[phx-value-action='stop']:not([disabled])") ==
               unquote(stop?)

      assert has_element?(ctx.view, "button[phx-value-action='logs']:not([disabled])", "Logs")
      refute has_element?(ctx.view, "button.ghost[phx-click='preview']")
    end
  end

  test "preview startup keeps logs collapsed and failure opens diagnostics", ctx do
    logs = ~s({"type":"stdout","data":"app booting"})

    stub(Previews, :status, fn _, _ ->
      {:ok, %{preview() | state: :starting, logs: logs, config: %{readiness_path: "/health"}}}
    end)

    render_click(ctx.view, "panel", %{name: "preview"})
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "#preview-loading[role=status]",
             "Waiting for it to answer on /health"
           )

    assert has_element?(ctx.view, "#preview-logs:not([open]) summary", "Show logs")
    assert has_element?(ctx.view, "#preview-logs:not([open]) pre", "[stdout] app booting")
    refute has_element?(ctx.view, ".workspace-preview")
    refute render(ctx.view) =~ ~s(&quot;type&quot;)

    stub(Previews, :status, fn _, _ ->
      {:ok, %{preview() | state: :failed, logs: logs, error: "App did not answer"}}
    end)

    render_click(ctx.view, "refresh-panel")
    render_async(ctx.view)
    refute has_element?(ctx.view, "#preview-loading")
    assert has_element?(ctx.view, "[role=alert]", "App did not answer")
    assert has_element?(ctx.view, "#preview-logs[open] pre", "[stdout] app booting")
  end

  test "Run launches the stopped preview and disables controls until the response", ctx do
    stub(Previews, :status, fn _, _ -> {:ok, preview()} end)
    render_click(ctx.view, "panel", %{name: "preview"})
    render_async(ctx.view)
    owner = self()

    expect(Previews, :run, fn user, id ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      send(owner, {:launching, self()})
      receive do: (:finish -> {:ok, %{preview() | state: :starting}})
    end)

    ctx.view |> element("button[phx-value-action='run']", "Run") |> render_click()
    assert_receive {:launching, task}
    refute has_element?(ctx.view, "button[phx-click='preview']:not([disabled])")
    send(task, :finish)
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "button[phx-value-action='restart-run']:not([disabled])",
             "Restart"
           )
  end

  test "unavailable previews disable launch controls but retain logs", ctx do
    stub(Previews, :status, fn _, _ ->
      {:ok,
       %{preview() | available: false, unavailable_reason: "Preview domain is not configured"}}
    end)

    render_click(ctx.view, "panel", %{name: "preview"})
    render_async(ctx.view)
    assert has_element?(ctx.view, "button[phx-value-action='run'][disabled]", "Run")
    assert has_element?(ctx.view, "button[phx-value-action='stop'][disabled]")
    assert has_element?(ctx.view, "button[phx-value-action='logs']:not([disabled])")
  end

  test "preview actions keep status and use fresh tickets for the iframe", ctx do
    stub(Previews, :status, fn _, _ ->
      {:ok, %{preview() | state: :ready, url: "https://preview.test"}}
    end)

    render_click(ctx.view, "panel", %{name: "preview"})
    render_async(ctx.view)

    answered =
      struct!(preview(),
        state: :ready,
        logs: "service output",
        url: "https://preview.test",
        open_url: "https://preview.test/__ravix/open#fresh"
      )

    # Two arities, because the two that mint a ticket are the two that need
    # the session hash and the other two are not handed one at all. That
    # distinction only exists once the verb is in the function name.
    for action <- [:open] do
      expect(Previews, action, fn user, id, hash ->
        assert {user.id, id} == {ctx.user.id, ctx.track.id}
        assert is_binary(hash)
        {:ok, answered}
      end)

      ctx.view |> element("button[phx-value-action='#{action}']") |> render_click()
      assert render_async(ctx.view) =~ "service output"
    end

    expect(Previews, :run, fn user, id, :restart ->
      assert {user.id, id} == {ctx.user.id, ctx.track.id}
      {:ok, answered}
    end)

    ctx.view |> element("button[phx-value-action='restart-run']") |> render_click()
    assert render_async(ctx.view) =~ "service output"

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

  for action <- ["run", "restart-run", "stop"] do
    @run_action action
    test "revoked sessions cannot #{action} the run script", ctx do
      token = Plug.Conn.get_session(ctx.conn, :session_token)
      Repo.delete!(Repo.get_by!(Session, token_hash: Ravix.Crypto.sha256(token)))

      :sys.replace_state(ctx.view.pid, fn state ->
        update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
      end)

      reject(&Previews.run/2)
      reject(&Previews.run/3)
      reject(&Previews.stop/2)

      assert {:error, {:redirect, %{to: "/login"}}} =
               render_click(ctx.view, "preview", %{action: @run_action})
    end
  end

  test "plain running process shows output and restart/stop but no preview link", ctx do
    info = %{
      preview()
      | state: :running,
        keeps_awake: true,
        config: %{directory: ".", command: "worker", readiness_path: nil},
        logs: "worker output"
    }

    stub(Previews, :status, fn _, _ -> {:ok, info} end)
    render_click(ctx.view, "panel", %{name: "preview"})
    render_async(ctx.view)
    assert has_element?(ctx.view, "#run-status", "running")

    assert has_element?(
             ctx.view,
             "#run-keeps-awake",
             "Keeps this track's machine awake while running"
           )

    assert has_element?(ctx.view, "#preview-logs pre", "worker output")
    assert has_element?(ctx.view, "button[phx-value-action='restart-run']:not([disabled])")
    assert has_element?(ctx.view, "button[phx-value-action='stop']:not([disabled])")
    refute has_element?(ctx.view, "button[phx-value-action='open']")
    refute has_element?(ctx.view, "iframe.workspace-preview")
    expect(Previews, :stop, fn _, _ -> {:ok, %{info | state: :stopped}} end)
    ctx.view |> element("button[phx-value-action='stop']") |> render_click()
    render_async(ctx.view)
    assert has_element?(ctx.view, "#run-status", "stopped")
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
    # Shared CI/database load can exceed LiveViewTest's 100ms default.
    render_async(ctx.view, 5_000)

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

  test "a private invitee who owns the project sees no creator management controls", ctx do
    creator = insert_user()
    insert_project_member(ctx.project, creator)
    insert_track_member(ctx.track, ctx.user)

    Repo.update!(
      Ecto.Changeset.change(ctx.track,
        created_by: creator.id,
        visibility: :private,
        sandbox_layout: :dedicated,
        sandbox_state: :ready
      )
    )

    send(ctx.view.pid, {:hub, Event.new(:people, ctx.project.id, track_id: ctx.track.id)})
    settle(ctx.view)
    refute has_element?(ctx.view, "[phx-value-name=rename]")
    refute has_element?(ctx.view, "[phx-value-name=close]")
    refute has_element?(ctx.view, "[phx-value-name=rebuild]")
    render_click(ctx.view, "dialog", %{name: "people"})
    refute has_element?(ctx.view, "#track-visibility-form")
    refute has_element?(ctx.view, "[phx-submit=invite-person]")
  end

  test "shared track sharing explains and refuses private visibility", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.track, created_by: ctx.user.id))
    send(ctx.view.pid, {:hub, Event.new(:people, ctx.project.id, track_id: ctx.track.id)})
    settle(ctx.view)
    render_click(ctx.view, "dialog", %{name: "people"})
    refute has_element?(ctx.view, "#track-visibility-form option[value='private']")
    message = "Private tracks need their own machine. This track shares the project machine."
    assert has_element?(ctx.view, "#track-visibility-form", message)
    ctx.view |> element("#track-visibility-form") |> render_change(%{"visibility" => "private"})
    assert toasted(ctx) =~ message
    assert Repo.get!(Track, ctx.track.id).visibility == :project
  end

  test "creator changes sharing in People and a revoked session cannot change it", ctx do
    Repo.update!(
      Ecto.Changeset.change(ctx.track, created_by: ctx.user.id, sandbox_layout: :dedicated)
    )

    send(ctx.view.pid, {:hub, Event.new(:people, ctx.project.id, track_id: ctx.track.id)})
    settle(ctx.view)
    render_click(ctx.view, "dialog", %{name: "people"})
    assert has_element?(ctx.view, "#track-visibility-form")
    ctx.view |> form("#track-visibility-form", visibility: "private") |> render_change()
    assert Repo.get!(Track, ctx.track.id).visibility == :private
    settle(ctx.view)
    assert has_element?(ctx.view, ".track-crumbs", "Private")
    token = Plug.Conn.get_session(ctx.conn, :session_token)
    session = Repo.get_by!(Session, token_hash: Ravix.Crypto.sha256(token))
    Repo.delete!(session)

    :sys.replace_state(ctx.view.pid, fn state ->
      update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
    end)

    assert {:error, {:redirect, %{to: "/login"}}} =
             ctx.view |> form("#track-visibility-form", visibility: "project") |> render_change()

    assert Repo.get!(Track, ctx.track.id).visibility == :private
  end

  test "track invites can be minted, revoked, and members removed", ctx do
    member = insert_user()
    People.Store.add_member(ctx.track.id, member.id, ctx.user.id)
    render_click(ctx.view, "dialog", %{name: "people"})
    ctx.view |> element("button", "Create invite link") |> render_click()
    assert has_element?(ctx.view, "#track-people-dialog a[href*='/j/']")
    ctx.view |> element("button", "Revoke invite link") |> render_click()
    refute has_element?(ctx.view, "#track-people-dialog a[href*='/j/']")

    ctx.view
    |> element("button[phx-click=remove-person][phx-value-login='#{member.login}']")
    |> render_click()

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

  test "the header names the track once and keeps its actions to labelled icons", ctx do
    header = fn view -> element(view, ".track-crumbs") end

    # This track's title and branch differ, so the chip still says something
    # the title does not.
    assert has_element?(ctx.view, ".track-crumbs .track-branch", ctx.track.branch)

    refute has_element?(ctx.view, ".track-crumbs button[aria-label='Project settings']")

    # New track lives once, at the end of the tab strip above; the header
    # does not offer it a second time.
    refute has_element?(ctx.view, ".track-crumbs button[aria-label='New track']")

    # Buttons whose only text is an icon: nothing visible is left to read.
    refute render(header.(ctx.view)) =~ ~r/>\s*(New track|Settings)\s*</

    refute has_element?(ctx.view, ".track-crumbs button[title='Project settings']")
    assert has_element?(ctx.view, ".track-crumbs button[title='Rename track']")

    assert has_element?(
             ctx.view,
             ".track-crumbs button[aria-label^='Track sharing'][title$='viewing now)']"
           )

    refute has_element?(ctx.view, "#track-actions-menu")

    ctx.view
    |> element(".track-crumbs button[aria-label='Close track'][title='Close track']")
    |> render_click()

    assert has_element?(ctx.view, "#close-form")

    # A track still titled with its branch shows the name once.
    Repo.update!(Ecto.Changeset.change(Repo.get!(Track, ctx.track.id), title: ctx.track.branch))
    {:ok, parent, _} = live(ctx.conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    settle(view)
    assert has_element?(view, ".track-crumbs button", ctx.track.branch)
    refute has_element?(view, ".track-crumbs .track-branch")
  end

  test "a member who neither owns nor opened the track has no close action", ctx do
    member = insert_user()
    People.Store.add_project_member(ctx.project.id, member.id, ctx.user.id)

    stub(Tracks, :get, fn _, id, _opts ->
      row = Repo.get!(Track, id)

      {:ok,
       %{
         track: Tracks.present(row, role: :member),
         header: blank_header(),
         threads: thread_options(id),
         starters: [],
         models: []
       }}
    end)

    {:ok, parent, _} =
      live(log_in_user(build_conn(), member), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    settle(view)
    assert has_element?(view, ".track-crumbs button[aria-label^='Track sharing']")
    refute has_element?(view, ".track-crumbs button[aria-label='Project settings']")
    refute has_element?(view, "#track-actions-toggle")
    refute has_element?(view, "button", "Close track")
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
    # The funding component rechecks its session before applying the async answer.
    assert Enum.count(sources, &(&1 == "sessions")) == 1
  end

  # What one hub event costs the page, in queries, once it has settled.
  # `render_async/1` waits on the async reads outstanding when it is called,
  # and not on any that those start in turn. A load now starts its four reads
  # together, so one call is usually enough --- but the transcript's result
  # can still establish a follower, and a second call costs nothing and keeps
  # the next thing a test measures from paying for somebody else's read.
  # A turn's opening event as the feed serves it with `?prompts=true`, which is
  # where the transcript reads what somebody asked for.
  describe "the composer's @ files and / commands" do
    defp composer_commands(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#composer-form textarea[phx-hook=Composer]")
      |> LazyHTML.attribute("data-commands")
      |> case do
        [json] -> json |> Jason.decode!() |> Enum.map(&{&1["name"], &1["source"], &1["event"]})
        [] -> nil
      end
    end

    defp advertised(id, names) do
      line =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            update: %{
              sessionUpdate: "available_commands_update",
              availableCommands: Enum.map(names, &%{name: &1, description: "Does #{&1}"})
            }
          }
        })

      %{"id" => id, "turn_id" => "t1", "kind" => "output", "stream" => "acp", "data" => line}
    end

    test "the box advertises them, names its list, and offers Ravix's actions as commands", ctx do
      assert has_element?(
               ctx.view,
               "#composer-form textarea[aria-controls=composer-suggestions][aria-autocomplete=list]" <>
                 "[aria-keyshortcuts='Control+L Meta+L'][data-files-event=mention-files]" <>
                 "[placeholder='Ask to make changes, @mention files, run /commands']"
             )

      assert has_element?(
               ctx.view,
               "#composer-suggestions[role=listbox][phx-update=ignore][hidden][aria-label=Suggestions]"
             )

      assert has_element?(ctx.view, "#composer-suggestions-status[role=status].sr-only")
      assert has_element?(ctx.view, "#composer-shortcut kbd", "Ctrl+L")

      # The track is still opening, so, like the Stop button, `/stop` is there.
      assert composer_commands(ctx.view) == [
               {"stop", "ravix", "interrupt"},
               {"new", "ravix", "draft-thread"},
               {"comment", "ravix", "composer-mode"},
               {"changes", "ravix", "panel"},
               {"checks", "ravix", "panel"}
             ]

      # Comment mode has its own list of people and no commands.
      render_click(ctx.view, "composer-mode", %{mode: "comment"})
      assert has_element?(ctx.view, "#composer-form textarea[aria-controls=mention-options]")
      refute has_element?(ctx.view, "#composer-suggestions")
      assert composer_commands(ctx.view) == nil
    end

    test "the agent's advertised commands come first, from the transcript and then live", ctx do
      page =
        Transcript.page(
          [opened(1, "t1", "Hello"), advertised(2, ["review", "has space"])],
          "claude"
        )

      stub(Tracks, :events, fn _, _, _ -> {:ok, page} end)
      render_click(ctx.view, "retry-load")
      render_async(ctx.view)

      assert [{"review", "agent", nil} | ravix] = composer_commands(ctx.view)
      assert length(ravix) == 5

      assert has_element?(
               ctx.view,
               "#composer-form textarea[placeholder='Add a follow-up, @mention files, run /commands']"
             )

      # A newer list replaces it; output that is not a list leaves it alone.
      send(ctx.view.pid, {:transcript, ctx.track.id, advertised(3, ["plan", "compact"])})
      send(ctx.view.pid, {:transcript, ctx.track.id, %{advertised(4, []) | "data" => "text"}})

      assert [{"plan", "agent", nil}, {"compact", "agent", nil} | _] =
               composer_commands(drawn(ctx.view))

      # Stop is a command only while there is something to stop.
      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Track, ctx.track.id),
          setup_state: "ready",
          opened_at: DateTime.utc_now()
        )
      )

      send(
        ctx.view.pid,
        {:hub, %Event{name: :tracks, project_id: ctx.project.id, track_id: ctx.track.id}}
      )

      render_async(ctx.view)
      refute Enum.any?(composer_commands(ctx.view), &match?({"stop", _, _}, &1))
    end

    test "@ reads the track's files once and answers from what it read", ctx do
      index = %Files.Index{paths: ["README.md", "lib/app.ex"], truncated: false}
      test_pid = self()

      expect(Tracks, :file_index, fn user, id ->
        send(test_pid, {:indexed, user.id, id})
        {:ok, index}
      end)

      render_hook(ctx.view, "mention-files", %{})
      render_async(ctx.view)
      assert_receive {:indexed, user_id, track_id}
      assert {user_id, track_id} == {ctx.user.id, ctx.track.id}

      assert_push_event(ctx.view, "composer:files", %{
        paths: ["README.md", "lib/app.ex"],
        truncated: false
      })

      # The second `@` is answered from memory; `expect` above allows one read.
      render_hook(ctx.view, "mention-files", %{})
      assert_push_event(ctx.view, "composer:files", %{paths: ["README.md", "lib/app.ex"]})
    end

    test "@ on a sleeping or unreachable machine says so instead of listing nothing", ctx do
      stub(Tracks, :file_index, fn _, _ -> {:error, :machine_asleep} end)
      render_hook(ctx.view, "mention-files", %{})
      render_async(ctx.view)
      assert_push_event(ctx.view, "composer:files", %{paths: [], error: asleep})
      assert asleep =~ "asleep"

      stub(Tracks, :file_index, fn _, _ ->
        {:error, {:conflict, "no_machine", "No machine yet."}}
      end)

      render_hook(ctx.view, "mention-files", %{})
      render_async(ctx.view)
      assert_push_event(ctx.view, "composer:files", %{paths: [], error: "No machine yet."})

      stub(Tracks, :file_index, fn _, _ -> exit(:boom) end)

      ExUnit.CaptureLog.capture_log(fn ->
        render_hook(ctx.view, "mention-files", %{})
        render_async(ctx.view)
      end)

      assert_push_event(ctx.view, "composer:files", %{
        paths: [],
        error: "Could not read the files."
      })
    end
  end

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
    # Shared CI/database load can exceed LiveViewTest's 100ms default during setup.
    render_async(view, 5_000)
    render_async(view, 5_000)
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

  test "panel actions reveal the inspector from conversation and commands", ctx do
    for view <- ["conversation", "terminal"] do
      render_click(ctx.view, "narrow-view", %{name: view})
      render_click(ctx.view, "panel", %{name: "preview"})
      assert has_element?(ctx.view, "[data-narrow-view='files']")
      assert has_element?(ctx.view, ".workspace-tabs button.selected[phx-value-name='preview']")
      render_async(ctx.view, 1000)
    end
  end

  test "unknown or missing narrow view names leave the page unchanged", ctx do
    render_click(ctx.view, "narrow-view", %{name: "terminal"})

    for params <- [%{name: "retired"}, %{name: nil}, %{}] do
      render_click(ctx.view, "narrow-view", params)
      assert has_element?(ctx.view, "[data-narrow-view='terminal']")
    end

    render_click(ctx.view, "narrow-view", %{name: "conversation"})
    assert has_element?(ctx.view, "[data-narrow-view='conversation']")
  end

  test "narrow views switch without discarding the conversation or dock", ctx do
    assert has_element?(ctx.view, "[data-narrow-view='conversation']")
    ctx.view |> element("[phx-click='narrow-view'][phx-value-name='files']") |> render_click()
    assert has_element?(ctx.view, "[data-narrow-view='files']")
    ctx.view |> element("[phx-click='narrow-view'][phx-value-name='terminal']") |> render_click()
    assert has_element?(ctx.view, "[data-narrow-view='terminal']")
    assert has_element?(ctx.view, "#machine-dock:not([hidden])")

    ctx.view
    |> element("[phx-click='narrow-view'][phx-value-name='conversation']")
    |> render_click()

    assert has_element?(ctx.view, "[data-narrow-view='conversation']")
    assert has_element?(ctx.view, "#track-terminal")
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

    assert has_element?(
             ctx.view,
             ".track-crumbs button[aria-label='Track sharing (1 viewing now)'][title='Track sharing (1 viewing now)']",
             "1"
           )

    send(ctx.view.pid, :refresh)
    assert render_async(ctx.view) =~ "Start here"
  end

  test "minute refresh makes no event requests and live output still appends", ctx do
    client = FakeTransport.client([])
    stub(Ravix.Fountain, :client, fn -> client end)
    # Exercise the actual scoped read if the timer accidentally asks for it.
    stub(Tracks, :events, &Mimic.call_original(Tracks, :events, [&1, &2, &3]))
    send(ctx.view.pid, :refresh)
    render_async(ctx.view)
    assert FakeTransport.calls(client) == []

    send(ctx.view.pid, {:transcript, ctx.track.id, opened(99, "after-tick", "Still streaming")})
    assert render(drawn(ctx.view)) =~ "Still streaming"
    render_async(ctx.view)
    assert FakeTransport.calls(client) == []
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

    send(ctx.view.pid, {:hub, Event.new(:turn, ctx.project.id, track_id: ctx.track.id)})
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
    assert html =~ "Machine setup failed"
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

  test "prompt thumbnails stay with their turn in snapshots and image-only live updates", ctx do
    page =
      [opened(1, "with-images", "Look at these"), opened(2, "text-only", "Just text")]
      |> Transcript.page("claude")
      |> Transcript.with_images([Shapes.turn(%{"id" => "with-images", "image_count" => 2})])

    stub(Tracks, :events, fn _, _, _ -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)

    base = "/tracks/#{ctx.track.id}/threads/#{ctx.track.id}/turns/with-images/images/"

    for position <- 0..1 do
      assert has_element?(ctx.view, "#turns-with-images .said img[src='#{base}#{position}']")

      assert has_element?(
               ctx.view,
               "#turns-with-images a[href='#{base}#{position}'][target='_blank']"
             )
    end

    refute has_element?(ctx.view, "#turns-text-only img")

    event = opened(3, "image-only", "") |> Transcript.Event.from() |> Map.put(:image_count, 1)
    send(ctx.view.pid, {:transcript, ctx.track.id, event})
    drawn(ctx.view)
    assert has_element?(ctx.view, "#turns-image-only .said img[alt='Attached image 1']")
    refute has_element?(ctx.view, "#turns-image-only .workspace-prompt")

    # A replay without metadata must not erase the attachments.
    send(ctx.view.pid, {:transcript, ctx.track.id, opened(3, "image-only", "")})
    drawn(ctx.view)
    assert has_element?(ctx.view, "#turns-image-only .said img")
  end

  test "a new transcript shows its setup card without the internal bootstrap or machine path",
       ctx do
    page =
      Transcript.page(
        [
          opened(
            1,
            "bootstrap",
            "[ravix] Open this track. Make its working directory, then stop.\nInternal commands"
          )
        ],
        "claude"
      )

    stub(Tracks, :events, fn _, _, _ -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)

    assert has_element?(ctx.view, ".track-ribbon", ctx.track.branch)
    refute has_element?(ctx.view, ".track-ribbon", ctx.track.workdir)
    refute has_element?(ctx.view, "#turns-bootstrap")
    assert has_element?(ctx.view, ".workspace-welcome", "What are we working on?")

    assert has_element?(
             ctx.view,
             "#composer-form textarea[placeholder='Ask to make changes, @mention files, run /commands']"
           )

    assert has_element?(ctx.view, ~s|.jump-latest svg path[d="M12 5v14M6 13l6 6 6-6"]|)
  end

  test "an additional thread's working-directory line stays out of the prompt shown", ctx do
    track = Repo.get!(Track, ctx.track.id)
    row = %{thread_id: "other-thread", track_id: track.id}

    for {id, said, speaker} <- [
          {"solo", PromptQueue.Body.in_thread("Fix the build", row, track), "User"},
          {"shared",
           PromptQueue.with_author(
             "teammate",
             PromptQueue.Body.in_thread("Fix the build", row, track)
           ), "@teammate"}
        ] do
      send(ctx.view.pid, {:transcript, ctx.track.id, opened(200, id, said)})
      drawn(ctx.view)
      assert has_element?(ctx.view, "#turns-#{id} .speaker", speaker)
      assert has_element?(ctx.view, "#turns-#{id} .workspace-prompt", "Fix the build")
      refute has_element?(ctx.view, "#turns-#{id}", "This conversation shares track")
    end

    # A Ravix instruction that is only the line is still Ravix's.
    assert PromptQueue.Body.outside_thread("[ravix] This conversation shares track x.") ==
             "[ravix] This conversation shares track x."
  end

  test "restored context and preview instructions stay out of an authored prompt", ctx do
    preview =
      Ravix.Previews.Agent.start_marker() <>
        "\nhidden tools\n" <>
        Ravix.Previews.Agent.end_marker()

    prompt =
      Enum.join(
        [
          Ravix.Spec.session_recovery_prompt(ctx.track, []),
          preview,
          PromptQueue.with_author("teammate", "Continue my work")
        ],
        "\n\n"
      )

    send(ctx.view.pid, {:transcript, ctx.track.id, opened(100, "restored", prompt)})
    drawn(ctx.view)
    assert has_element?(ctx.view, "#turns-restored .speaker", "@teammate")
    assert has_element?(ctx.view, "#turns-restored .workspace-prompt", "Continue my work")
    assert has_element?(ctx.view, "#turns-restored .chip", "Context restored")
    html = render(ctx.view)
    refute html =~ "Earlier turns may be missing"
    refute html =~ "hidden tools"
    refute html =~ "[from @"

    page = Transcript.page([opened(100, "restored", prompt)], "claude")
    stub(Tracks, :events, fn _, _, _ -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)
    assert has_element?(ctx.view, "#turns-restored .speaker", "@teammate")
    assert has_element?(ctx.view, "#turns-restored .chip", "Context restored")
    refute render(ctx.view) =~ "Earlier turns may be missing"
  end

  test "saved setup failures show human recovery guidance without MCP tool names", ctx do
    ctx.track |> Ecto.Changeset.change(setup_state: "failed") |> Repo.update!()
    id = Ecto.UUID.generate()

    {:ok, _} =
      PromptQueue.Store.enqueue(ctx.track.id, ctx.user.id, ctx.user.login, id, %{
        prompt: "Saved work",
        images: []
      })

    PromptQueue.Store.fail_setup(
      ctx.track.id,
      Setup.failure_message() <> " Opening was refused."
    )

    send(ctx.view.pid, {:hub, Event.new(:queue, ctx.project.id, track_id: ctx.track.id)})
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             ".workspace-queue",
             "Track setup failed. Retry setup, then retry this saved prompt. Opening was refused."
           )

    refute has_element?(ctx.view, ".workspace-queue", "retry_setup")
    refute has_element?(ctx.view, ".workspace-queue", "retry_task")
  end

  test "saved prompts explain statuses, busy waits and a held head", ctx do
    ids =
      for {status, reason} <- [
            queued: "Waiting for the current turn to finish",
            sending: nil,
            failed: "Refused",
            unconfirmed: "Unknown",
            queued: nil
          ] do
        id = Ecto.UUID.generate()

        {:ok, _} =
          PromptQueue.Store.enqueue(ctx.track.id, ctx.user.id, ctx.user.login, id, %{
            prompt: id,
            images: []
          })

        PromptQueue.Store.set_status(id, status, reason)
        id
      end

    refresh = fn ->
      send(ctx.view.pid, {:hub, Event.new(:queue, ctx.project.id, track_id: ctx.track.id)})
      render_async(ctx.view)
    end

    refresh.()

    for label <- ["Waiting", "Sending…", "Needs attention", "Not confirmed"] do
      assert has_element?(ctx.view, ".workspace-queue .chip", label)
    end

    for raw <- ~w(queued sending failed unconfirmed) do
      refute has_element?(ctx.view, ".workspace-queue .chip", raw)
    end

    assert has_element?(ctx.view, ".workspace-queue p", "Waiting for the current turn to finish")

    PromptQueue.Store.set_status(
      hd(ids),
      :queued,
      "The agent is at capacity; will retry",
      "sandbox_at_capacity"
    )

    refresh.()

    assert has_element?(
             ctx.view,
             ".workspace-queue p",
             "Claude Code is at capacity on this machine; your prompt is queued."
           )

    Enum.each(Enum.take(ids, 2), &PromptQueue.Store.set_status(&1, :sent))
    refresh.()

    for head <- Enum.slice(ids, 2, 2) do
      assert {:ok, %{blocked_by: %{id: ^head}}} =
               PromptQueue.status(ctx.user, ctx.track.id, List.last(ids))

      assert {:ok, queue} = PromptQueue.list(ctx.user, ctx.track.id)
      assert List.last(queue).blocked_by.id == head

      assert has_element?(
               ctx.view,
               ".workspace-queue > div:last-child p",
               "Waiting behind a prompt that needs attention"
             )

      PromptQueue.Store.set_status(head, :sent)
      refresh.()
    end

    refute has_element?(ctx.view, ".workspace-queue p")
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

  test "a turn's work folds into one line above the answer it led to", ctx do
    update = fn data ->
      Jason.encode!(%{jsonrpc: "2.0", method: "session/update", params: %{update: data}})
    end

    text = fn kind, body -> %{sessionUpdate: kind, content: %{type: "text", text: body}} end

    frames = [
      text.("agent_thought_chunk", "Considering the change"),
      %{
        sessionUpdate: "tool_call",
        toolCallId: "ls",
        title: "git ls-remote origin HEAD",
        kind: "execute",
        rawInput: %{command: "git ls-remote origin HEAD", cwd: "/home/sprite/work/track"}
      },
      %{sessionUpdate: "tool_call_update", toolCallId: "ls", status: "completed"},
      text.("agent_message_chunk", "Checking the remote next"),
      %{
        sessionUpdate: "tool_call",
        toolCallId: "test",
        title: "Run tests",
        kind: "execute",
        rawInput: %{command: "mix test", cwd: "/home/sprite/work/track"}
      },
      %{sessionUpdate: "tool_call_update", toolCallId: "test", status: "failed"},
      text.("agent_message_chunk", "The answer")
    ]

    events =
      frames
      |> Enum.with_index(1)
      |> Enum.map(fn {data, id} ->
        %{
          "id" => id,
          "turn_id" => "turn",
          "kind" => "output",
          "stream" => "acp",
          "data" => update.(data)
        }
      end)

    page = Transcript.page([opened(0, "turn", "User prompt") | events], "claude")
    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "#turns-turn .workspace-work > summary",
             "2 tool calls, 1 message, 1 thought"
           )

    # The folded line counts work, never failures.
    refute has_element?(ctx.view, "#turns-turn .workspace-work > summary .chip")
    assert has_element?(ctx.view, "#turns-turn .workspace-work-body .md", "Checking the remote")
    refute has_element?(ctx.view, "#turns-turn .workspace-work", "The answer")
    assert has_element?(ctx.view, "#turns-turn .agent-terminal-output > div > .md", "The answer")

    # A command the title already names is not repeated, the working
    # directory stays in the expanded arguments, and success needs no chip.
    refute has_element?(ctx.view, "#turns-turn .tool-summary", "git ls-remote")
    assert has_element?(ctx.view, "#turns-turn .tool-summary", "mix test")
    refute render(ctx.view) =~ "cwd="
    refute has_element?(ctx.view, "#turns-turn .workspace-tool .chip", "done")
    assert has_element?(ctx.view, "#turns-turn .workspace-tool .chip.tool-error", "error")

    # While a call runs, the folded line says which.
    send(
      ctx.view.pid,
      {:transcript, ctx.track.id,
       %{
         "id" => 20,
         "turn_id" => "turn",
         "kind" => "output",
         "stream" => "acp",
         "data" =>
           update.(%{
             sessionUpdate: "tool_call",
             toolCallId: "build",
             title: "mix compile",
             kind: "execute",
             rawInput: %{command: "mix compile"}
           })
       }}
    )

    drawn(ctx.view)
    assert has_element?(ctx.view, "#turns-turn .workspace-work .work-now", "mix compile")
    assert has_element?(ctx.view, "#turns-turn .workspace-work > summary", "3 tool calls")
    assert has_element?(ctx.view, "#turns-turn .workspace-work-body .md", "The answer")
  end

  for {scenario, status, following, ending, recovered, failed} <- [
        {"recovered by another call", "failed", :tool, "completed", 1, 0},
        {"recovered by an answer", "failed", :text, "completed", 1, 0},
        {"final error", "failed", :none, "completed", 0, 1},
        {"turn failure after recovery", "failed", :tool, "failed", 0, 1},
        {"no errors", "completed", :text, "completed", 0, 0},
        {"failure without tool errors", "completed", :text, "failed", 0, 0},
        {"still running", "failed", :tool, nil, 0, 1},
        {"cancelled", "failed", :text, "cancelled", 0, 1}
      ] do
    @tag scenario: {status, following, ending, recovered, failed}
    test "work summary: #{scenario}", ctx do
      {status, following, ending, recovered, failed} = ctx.scenario
      call = %{sessionUpdate: "tool_call", toolCallId: "test", title: "mix test", kind: "execute"}

      result = %{
        sessionUpdate: "tool_call_update",
        toolCallId: "test",
        status: status,
        content: [%{type: "content", content: %{type: "text", text: "Original command output"}}]
      }

      after_error =
        case following do
          :tool ->
            [
              %{call | toolCallId: "retry"},
              %{result | toolCallId: "retry", status: "completed"}
            ]

          :text ->
            [%{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "Done"}}]

          :none ->
            []
        end

      events =
        [call, result | after_error]
        |> Enum.with_index(1)
        |> Enum.map(fn {update, id} ->
          %{
            "id" => id,
            "turn_id" => "turn",
            "kind" => "output",
            "stream" => "acp",
            "data" =>
              Jason.encode!(%{
                jsonrpc: "2.0",
                method: "session/update",
                params: %{update: update}
              })
          }
        end)

      terminal =
        if ending,
          do: [
            %{
              "id" => 99,
              "turn_id" => "turn",
              "kind" => "stage",
              "stage" => "turn",
              "state" => ending
            }
          ],
          else: []

      page = Transcript.page([opened(0, "turn", "Test") | events] ++ terminal, "claude")
      stub(Tracks, :events, fn _, _, _ -> {:ok, page} end)
      render_click(ctx.view, "retry-load")
      render_async(ctx.view)

      # Whatever happened to the calls, the folded line carries no failure or
      # recovery chip: the turn's own failure block is the only alarm.
      summary = "#turns-turn .workspace-work > summary"
      _ = {recovered, failed}
      refute has_element?(ctx.view, summary <> " .chip")

      assert has_element?(ctx.view, "#turns-turn .workspace-tool .tool-error") ==
               (status == "failed")

      assert has_element?(ctx.view, "#turns-turn .workspace-work-body", "Original command output")

      if ending == "failed" do
        assert has_element?(
                 ctx.view,
                 "#turns-turn .agent-terminal-output > div .workspace-failure"
               )
      end
    end
  end

  test "a finished turn says how long it ran, what it touched, and offers its answer", ctx do
    update = fn data ->
      Jason.encode!(%{jsonrpc: "2.0", method: "session/update", params: %{update: data}})
    end

    workdir = ctx.track |> Repo.reload!() |> Map.fetch!(:workdir)

    edit = fn id, path, old, new ->
      [
        %{sessionUpdate: "tool_call", toolCallId: id, title: "Edit", kind: "edit"},
        %{
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "completed",
          content: [%{type: "diff", path: path, oldText: old, newText: new}]
        }
      ]
    end

    frames =
      edit.("a", "#{workdir}/lib/app.ex", "one", "one\ntwo") ++
        edit.("b", "#{workdir}/lib/app.ex", "x", "y") ++
        edit.("c", "#{workdir}/README.md", "", "hello") ++
        edit.("d", "/elsewhere/notes.txt", "a\nb", "") ++
        [%{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "**Done**"}}]

    output =
      frames
      |> Enum.with_index(1)
      |> Enum.map(fn {data, id} ->
        %{
          "id" => id,
          "turn_id" => "turn",
          "kind" => "output",
          "stream" => "acp",
          "data" => update.(data),
          "ts" => "2026-09-26T13:00:30Z"
        }
      end)

    started = Map.put(opened(0, "turn", "Change things"), "ts", "2026-09-26T13:00:00Z")

    completed = %{
      "id" => 99,
      "turn_id" => "turn",
      "kind" => "stage",
      "stage" => "turn",
      "state" => "completed",
      "ts" => "2026-09-26T13:02:05Z"
    }

    live = %{
      "id" => 100,
      "turn_id" => "live",
      "kind" => "output",
      "stream" => "acp",
      "data" =>
        update.(%{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "Going"}})
    }

    page = Transcript.page([started | output] ++ [completed, live], "claude")
    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)

    assert has_element?(ctx.view, "#turns-turn .turn-footer", "2m 5s")

    assert has_element?(
             ctx.view,
             ~s|#turns-turn .turn-footer time[datetime="2026-09-26T13:02:05Z"]|,
             "13:02 UTC"
           )

    assert has_element?(ctx.view, ~s|#turns-turn .turn-copy[data-copy="**Done**"]|)
    # Files are named from the track's directory, summed across edits, and
    # past the first two are counted rather than listed.
    assert has_element?(ctx.view, ~s|#turns-turn .turn-file[title="README.md"]|, "+1 −0")
    assert has_element?(ctx.view, ~s|#turns-turn .turn-file[title="/elsewhere/notes.txt"]|)
    assert has_element?(ctx.view, "#turns-turn .turn-file", "+1 more")
    assert has_element?(ctx.view, "#turns-turn .turn-file", "+2 −1")
    # A turn still running has no footer yet.
    refute has_element?(ctx.view, "#turns-live .turn-footer")
  end

  test "a running turn's elapsed time ticks in the browser until the server's duration replaces it",
       ctx do
    started = DateTime.add(DateTime.utc_now(), -95) |> DateTime.truncate(:second)

    chunk =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "session/update",
        params: %{
          update: %{
            sessionUpdate: "agent_message_chunk",
            content: %{type: "text", text: "Working"}
          }
        }
      })

    events = [
      Map.put(opened(201, "timed", "Take your time"), "ts", DateTime.to_iso8601(started)),
      %{
        "id" => 202,
        "turn_id" => "timed",
        "kind" => "output",
        "stream" => "acp",
        "data" => chunk,
        "ts" => DateTime.to_iso8601(DateTime.add(started, 3))
      }
    ]

    for event <- events, do: send(ctx.view.pid, {:transcript, ctx.track.id, event})
    drawn(ctx.view)

    # The start is written out so a reload resumes from it, not from zero,
    # and the server's own clock rides along for the hook to correct skew.
    timer =
      ctx.view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(
        ~s|#turns-timed .turn-running .turn-elapsed[phx-hook="TurnTimer"]| <>
          ~s|[data-started="#{DateTime.to_iso8601(started)}"]|
      )

    assert Enum.count(timer) == 1
    assert LazyHTML.text(timer) =~ ~r/^1m 3\ds$/

    assert {:ok, _now, 0} =
             timer |> LazyHTML.attribute("data-now") |> hd() |> DateTime.from_iso8601()

    refute has_element?(ctx.view, "#turns-timed .turn-footer time")

    ended = DateTime.add(started, 16 * 60 + 5)

    send(
      ctx.view.pid,
      {:transcript, ctx.track.id,
       %{
         "id" => 203,
         "turn_id" => "timed",
         "kind" => "stage",
         "stage" => "turn",
         "state" => "completed",
         "ts" => DateTime.to_iso8601(ended)
       }}
    )

    drawn(ctx.view)

    refute has_element?(ctx.view, "#turns-timed .turn-elapsed")
    refute has_element?(ctx.view, "#turns-timed .turn-running")
    assert has_element?(ctx.view, "#turns-timed .turn-footer", "16m 5s")
  end

  test "a turn with no tool calls or thoughts has nothing to fold", ctx do
    data =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "session/update",
        params: %{
          update: %{
            sessionUpdate: "agent_message_chunk",
            content: %{type: "text", text: "Just an answer"}
          }
        }
      })

    page =
      Transcript.page(
        [
          opened(0, "turn", "Hi"),
          %{"id" => 1, "turn_id" => "turn", "kind" => "output", "stream" => "acp", "data" => data}
        ],
        "claude"
      )

    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, page} end)
    render_click(ctx.view, "retry-load")
    render_async(ctx.view)

    assert has_element?(ctx.view, "#turns-turn .md", "Just an answer")
    refute has_element?(ctx.view, "#turns-turn .workspace-work")
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
       starters: [],
       models: []
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

    test "earlier turns prepend once while live output and catch-up retain their tail", ctx do
      history = %Transcript.History{chunks: [[%{"id" => 1}]], source: :fixture}

      page = %{
        transcript([{"new", "newest"}], from: 20)
        | history: history,
          conversation_id: "live-conversation",
          oldest_event_id: 20
      }

      repair(ctx, page)
      parent = self()

      expect(Tracks, :earlier_events, fn user, id, %Transcript.History{} = request, opts ->
        assert request == Transcript.History.request(history)
        assert user.id == ctx.user.id and id == ctx.track.id
        assert opts[:thread_id] == ctx.track.id
        send(parent, {:earlier_started, self()})
        receive do: (:finish -> :ok)

        older = %{
          transcript([{"old", "earlier"}])
          | history: %{history | chunks: []},
            oldest_event_id: 1
        }

        {:ok, older}
      end)

      render_click(ctx.view, "load-earlier", %{})
      assert_receive {:earlier_started, reader}
      assert has_element?(ctx.view, "#load-earlier[disabled]")
      render_click(ctx.view, "load-earlier", %{})
      send(ctx.view.pid, {:transcript, ctx.track.id, opened(30, "live", "Live prompt")})
      send(reader, :finish)
      render_async(ctx.view)
      send(ctx.view.pid, :flush_transcript)
      refute has_element?(ctx.view, "#load-earlier")
      html = render(ctx.view)
      assert html =~ "earlier" and html =~ "newest" and html =~ "Live prompt"
      # An in-flight repair based on the original history cannot erase a prepend.
      html = repair(ctx, page)
      assert html =~ "earlier" and html =~ "Live prompt"
      refute has_element?(ctx.view, "#load-earlier")
      assert has_element?(ctx.view, "#transcript-turns > article:first-child", "earlier")
      assert has_element?(ctx.view, "#transcript-turns > article:last-child", "Live prompt")
    end

    test "each earlier task receives only the next raw chunk and returns only new turns", ctx do
      history = %Transcript.History{chunks: [[%{"id" => 10}], [%{"id" => 1}]], source: :fixture}
      page = %{transcript([{"new", "held tail"}], from: 20) | history: history}
      repair(ctx, page)

      expect(Tracks, :earlier_events, fn _,
                                         _,
                                         %Transcript.History{chunks: [[%{"id" => 10}]]} = request,
                                         _ ->
        {:ok,
         %{transcript([{"middle", "middle chunk"}], from: 10) | history: %{request | chunks: []}}}
      end)

      render_click(ctx.view, "load-earlier", %{})
      render_async(ctx.view)
      assert has_element?(ctx.view, "#load-earlier:not([disabled])")
      assert has_element?(ctx.view, "#transcript-turns > article:first-child", "middle chunk")
      assert has_element?(ctx.view, "#transcript-turns > article:last-child", "held tail")

      expect(Tracks, :earlier_events, fn _,
                                         _,
                                         %Transcript.History{chunks: [[%{"id" => 1}]]} = request,
                                         _ ->
        {:ok, %{transcript([{"old", "oldest chunk"}]) | history: %{request | chunks: []}}}
      end)

      render_click(ctx.view, "load-earlier", %{})
      render_async(ctx.view)
      refute has_element?(ctx.view, "#load-earlier")
      assert has_element?(ctx.view, "#transcript-turns > article:first-child", "oldest chunk")
      assert has_element?(ctx.view, "#transcript-turns > article:last-child", "held tail")
    end

    test "newest-first history hands each task its cursor and keeps what it loaded across a fresh read",
         ctx do
      records = [
        %Ravix.Fountain.Shapes.Turn{
          id: "old",
          image_count: 1,
          prompt: nil,
          origin: nil,
          status: nil,
          inserted_at: nil,
          client_request_id: nil
        }
      ]

      history = %Transcript.History{
        before: 20,
        records: records,
        conversation_id: "live-conversation",
        source: :fixture
      }

      page = %{
        transcript([{"new", "newest"}], from: 20)
        | history: history,
          conversation_id: "live-conversation",
          oldest_event_id: 20
      }

      repair(ctx, page)

      expect(Tracks, :earlier_events, fn _, _, %Transcript.History{} = request, _ ->
        # A cursor crosses the task boundary whole: the next page's images
        # are among its records.
        assert request == history

        {:ok,
         %{
           transcript([{"middle", "middle page"}], from: 10)
           | history: %{request | before: 10},
             oldest_event_id: 10
         }}
      end)

      render_click(ctx.view, "load-earlier", %{})
      render_async(ctx.view)
      assert has_element?(ctx.view, "#load-earlier:not([disabled])")
      assert has_element?(ctx.view, "#transcript-turns > article:first-child", "middle page")

      expect(Tracks, :earlier_events, fn _, _, %Transcript.History{before: 10} = request, _ ->
        {:ok,
         %{
           transcript([{"old", "oldest page"}])
           | history: %{request | before: nil},
             oldest_event_id: 1
         }}
      end)

      render_click(ctx.view, "load-earlier", %{})
      render_async(ctx.view)
      refute has_element?(ctx.view, "#load-earlier")
      # A read that starts the thread over from its newest page keeps the
      # turns already loaded behind it, and the exhausted cursor.
      repair(ctx, page)
      refute has_element?(ctx.view, "#load-earlier")
      assert has_element?(ctx.view, "#transcript-turns > article:first-child", "oldest page")
      assert has_element?(ctx.view, "#transcript-turns > article:last-child", "newest")
    end

    for revoked <- [:session, :track] do
      test "#{revoked} revocation rejects an earlier-history result", ctx do
        page = %{transcript([{"new", "newest"}]) | history: %Transcript.History{chunks: [[]]}}
        repair(ctx, page)
        parent = self()

        expect(Tracks, :earlier_events, fn _, _, _, _ ->
          send(parent, {:earlier_started, self()})
          receive do: (:finish -> {:ok, page})
        end)

        render_click(ctx.view, "load-earlier", %{})
        assert_receive {:earlier_started, reader}

        case unquote(revoked) do
          :session ->
            token = Plug.Conn.get_session(ctx.conn, :session_token)
            Ravix.Accounts.end_session(Ravix.Crypto.sha256(token))

          :track ->
            Repo.delete!(Repo.get!(Track, ctx.track.id))
        end

        send(reader, :finish)

        assert_redirect(
          ctx.parent,
          if(unquote(revoked) == :session, do: "/login", else: "/"),
          1_000
        )
      end
    end

    test "earlier errors and crashes settle the control for retry", ctx do
      page = %{transcript([{"new", "newest"}]) | history: %Transcript.History{chunks: [[]]}}
      repair(ctx, page)
      expect(Tracks, :earlier_events, fn _, _, _, _ -> {:error, :not_found} end)
      render_click(ctx.view, "load-earlier", %{})
      render_async(ctx.view)
      refute has_element?(ctx.view, "#load-earlier[disabled]")
      expect(Tracks, :earlier_events, fn _, _, _, _ -> exit(:offline) end)
      render_click(ctx.view, "load-earlier", %{})
      render_async(ctx.view)
      refute has_element?(ctx.view, "#load-earlier[disabled]")
      assert render(ctx.parent) =~ "Could not load earlier history"
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

  for revocation <- [:session, :track], reader <- [:files, :file_metadata] do
    @revocation revocation
    @reader reader
    test "#{revocation} revocation rejects a delayed #{reader} result", ctx do
      parent = self()

      stub(Tracks, @reader, fn _, _, _ ->
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
  defp checks_fixture(state) do
    pull =
      Ravix.GitHub.Shapes.pull_ref(%{
        "number" => 209,
        "title" => "Fix track panels",
        "state" => if(state == :open, do: "open", else: "closed"),
        "merged_at" => if(state == :merged, do: "2026-09-26T10:00:00Z"),
        "html_url" => "https://github.com/acme/repo/pull/209"
      })

    %Ravix.GitHub.ChecksReport{ref: "track", sha: "abc", pushed: true, pull: pull, runs: []}
  end

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
    refute html =~ "What are we working on?"

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
         starters: [%{label: "Start here", prompt: "Build it"}],
         models: []
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

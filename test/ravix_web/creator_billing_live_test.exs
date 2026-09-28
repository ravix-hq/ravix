defmodule RavixWeb.CreatorBillingLiveTest do
  @moduledoc "What a creator-billed track shows its creator and its collaborators (ADR 0009 phase 6)."
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Fountain
  alias Ravix.Fountain.FakeTransport
  alias Ravix.{Repo, Tracks}
  alias Ravix.Tracks.{Billing, Track, Transcript}

  setup :verify_on_exit!

  setup do
    owner = insert_user(credential_set_id: "owner-set")

    creator =
      insert_user(
        credential_set_id: "creator-set",
        agent: :claude,
        credential_kind: :subscription
      )
      |> Ecto.Changeset.change(
        credential_connected_at: %{"claude:subscription" => "2026-09-01T00:00:00Z"}
      )
      |> Repo.update!()

    collab = insert_user()
    project = insert_project(user: owner, runtime: "claude", repo_full_name: nil)
    insert_project_member(project, creator)
    insert_project_member(project, collab)

    track =
      insert_track(
        project: project,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_id: "creator-disk-#{System.unique_integer([:positive])}",
        conversation_id: "creator-conversation-#{System.unique_integer([:positive])}",
        created_by: creator.id,
        created_by_login: creator.login
      )
      |> Ecto.Changeset.change()
      |> Track.creator_billing_changeset()
      |> Repo.update!()

    stub(Tracks, :get, fn user, id, _opts ->
      row = Repo.get!(Track, id)

      {:ok,
       %{
         track: Tracks.present(row, project: project, role: :member, viewer: user),
         header: %Ravix.Tracks.Header{
           copy_of: nil,
           branched_from: nil,
           created: %{dir: "x", files: nil},
           has_setup_script: false
         },
         threads: [%{id: id, title: "Main", runtime: "claude", unread: false}],
         starters: [],
         models: []
       }}
    end)

    stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _ -> :ok end)
    stub(Ravix.Accounts.Inference, :usable?, fn _, _, _ -> {:ok, true} end)
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)

    %{owner: owner, creator: creator, collab: collab, project: project, track: track}
  end

  defp open_track(ctx, user) do
    {:ok, parent, _} =
      live(log_in_user(build_conn(), user), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    render_async(view, 5_000)
    render_async(view, 5_000)
    {parent, view}
  end

  defp pause(ctx, text) do
    pause = Billing.from_failure(text, ctx.creator, "claude")
    :ok = Tracks.Store.pause_billing(ctx.track.id, "claude", pause)
    pause
  end

  test "collaborators see who pays; the creator sees that they do", ctx do
    {_parent, view} = open_track(ctx, ctx.collab)
    assert has_element?(view, "#track-payer", "Paid by @#{ctx.creator.login}")
    assert has_element?(view, "#composer-payer", "Paid by @#{ctx.creator.login}")
    refute has_element?(view, "#track-agent-owner")

    {_parent, view} = open_track(ctx, ctx.creator)
    assert has_element?(view, "#track-payer", "Paid by you")
    assert has_element?(view, "#composer-payer", "Paid by you")
  end

  test "the draft picker disables a harness the creator has not connected, for collaborators",
       ctx do
    {_parent, view} = open_track(ctx, ctx.collab)

    stub(Tracks, :thread_options, fn _, _ ->
      {:ok,
       %{
         runtime: "claude",
         model: "anthropic/claude-sonnet-5",
         source: :project,
         home_runtime: "claude",
         owner_login: ctx.creator.login,
         owner?: false,
         billing: :creator,
         runtimes: [
           %{
             runtime: "claude",
             connected: true,
             enabled: true,
             models: ["anthropic/claude-sonnet-5"]
           },
           %{runtime: "codex", connected: false, enabled: true, models: ["openai/gpt-6-astra"]}
         ]
       }}
    end)

    view |> element("#thread-switcher button[aria-label='Add thread']") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "#thread_draft-runtime option[value=codex][disabled]",
             "@#{ctx.creator.login} hasn't connected Codex"
           )

    refute has_element?(view, "button[phx-click=connect-thread-agent]")
  end

  test "a pause is shown to everybody; only the creator can try again", ctx do
    pause(ctx, "Claude AI usage limit reached")

    {_parent, view} = open_track(ctx, ctx.collab)

    assert has_element?(
             view,
             "#track-agent-health-pause",
             "Paused: @#{ctx.creator.login}'s Claude subscription is out of quota."
           )

    refute has_element?(view, "#track-agent-health-banner button", "Try again")
    view |> with_target("#track-agent-health") |> render_click("resume")
    assert Tracks.Store.get_track(ctx.track.id).billing_pauses != %{}

    {parent, view} = open_track(ctx, ctx.creator)
    assert has_element?(view, "#track-agent-health-banner button", "Try again")
    view |> element("#track-agent-health-banner button", "Try again") |> render_click()
    render_async(view, 5_000)
    assert Tracks.Store.get_track(ctx.track.id).billing_pauses == %{}
    refute has_element?(view, "#track-agent-health-pause")

    pause(ctx, "401 unauthorized")
    send(view.pid, :refresh_agent_health)
    render_async(view, 5_000)
    view |> element("#track-agent-health-banner button", "Reconnect") |> render_click()
    render(view)
    assert has_element?(parent, "#account-dialog")
  end

  test "the creator is told once that collaborators' prompts spend their subscription", ctx do
    {_parent, view} = open_track(ctx, ctx.creator)
    assert has_element?(view, "#billing-notice", "Collaborators' prompts here use your")
    view |> element("#billing-notice button", "Got it") |> render_click()
    refute has_element?(view, "#billing-notice")
    assert %DateTime{} = Tracks.Store.get_track(ctx.track.id).billing_notice_at

    {_parent, view} = open_track(ctx, ctx.creator)
    refute has_element?(view, "#billing-notice")

    {_parent, view} = open_track(ctx, ctx.collab)
    refute has_element?(view, "#billing-notice")
  end

  test "a paused creator-billed track is in its creator's Inbox and nobody else's", ctx do
    pause(ctx, "401 unauthorized")
    track = ctx.track

    client =
      FakeTransport.client(
        List.duplicate(
          {%{method: "GET", path: "/api/conversations"},
           {200, [],
            %{
              data: [
                %{
                  id: track.conversation_id,
                  status: "idle",
                  last_active_at: "2026-09-27T00:00:00Z",
                  sandbox_id: track.sandbox_id
                }
              ]
            }}},
          4
        ),
        verify: false
      )

    stub(Fountain, :client, fn -> client end)

    {:ok, view, _} = live(log_in_user(build_conn(), ctx.creator), "/inbox")
    render_async(view, 5_000)
    assert has_element?(view, ".inbox-item", "Reconnect")
    assert has_element?(view, ".inbox-item", "stopped working")

    {:ok, view, _} = live(log_in_user(build_conn(), ctx.collab), "/inbox")
    render_async(view, 5_000)
    refute has_element?(view, ".inbox-item", "Reconnect")
  end

  test "New track asks a creator with nothing connected to connect first", ctx do
    options = %{
      runtime: "claude",
      model: "anthropic/claude-sonnet-5",
      source: :project,
      home_runtime: "claude",
      owner_login: ctx.collab.login,
      owner?: true,
      billing: :creator,
      runtimes: [
        %{
          runtime: "claude",
          connected: false,
          enabled: true,
          models: ["anthropic/claude-sonnet-5"]
        },
        %{runtime: "codex", connected: false, enabled: true, models: ["openai/gpt-6-astra"]}
      ]
    }

    stub(Tracks, :open_options, fn user, _ ->
      assert user.id == ctx.collab.id
      {:ok, options}
    end)

    stub(Ravix.Accounts.Inference, :held, fn _ -> {:ok, []} end)
    stub(Ravix.Accounts.Inference, :subscription, fn _ -> {:ok, nil} end)

    stub(Ravix.Accounts.Inference, :link_status, fn _ ->
      {:ok, %{enabled?: true, pending: nil}}
    end)

    {:ok, view, _} = live(log_in_user(build_conn(), ctx.collab), "/p/#{ctx.project.id}")
    render_click(view, "dialog", %{name: "new-track"})
    render_async(view)

    assert has_element?(
             view,
             "#creator-connect-required",
             "Connect Claude or Codex to start a track — you pay for its agent."
           )

    assert has_element?(view, "#new-track-form button.primary[disabled]")

    view
    |> element("button[phx-click=connect-thread-agent][phx-value-runtime=claude]")
    |> render_click()

    render_async(view)

    assert has_element?(
             view,
             ".thread-connections form, .thread-connections button[phx-value-kind]"
           )
  end
end

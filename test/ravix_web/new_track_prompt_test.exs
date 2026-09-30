defmodule RavixWeb.NewTrackPromptTest do
  # The create dialog's optional first prompt (RAV-47): it is queued on the
  # new track's default thread through the same queue the composer uses, and
  # an empty one leaves creation as it was.
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Fountain.Client
  alias Ravix.{PromptQueue, Repo, Tracks}
  alias Ravix.Tracks.{Files, Track, Transcript}
  alias RavixWeb.Live.Guard

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)

    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    stub_track_page()

    stub(Tracks, :open_options, fn _, _ ->
      {:ok,
       %{
         runtime: "claude",
         model: "anthropic/claude-opus-5",
         owner_login: user.login,
         owner?: true,
         runtimes: [
           %{
             runtime: "claude",
             connected: true,
             enabled: true,
             models: ["anthropic/claude-opus-5"]
           }
         ]
       }}
    end)

    {token, session} = insert_session(user)
    conn = Plug.Test.init_test_session(conn, session_token: token)
    {:ok, view, _} = live(conn, "/p/#{project.id}")
    render_async(view, 1_000)
    %{view: view, user: user, project: project, session: session}
  end

  test "a prompt in the dialog is queued for its creator and shown waiting on the new track",
       ctx do
    track =
      insert_track(
        project: ctx.project,
        conversation_id: "first-conversation",
        created_by_login: ctx.user.login,
        setup_state: "pending"
      )

    expect(Tracks, :open, fn user, id, attrs ->
      assert {user.id, id} == {ctx.user.id, ctx.project.id}
      refute Map.has_key?(attrs, :prompt)
      {:ok, Tracks.present(track, role: :owner)}
    end)

    open_dialog(ctx.view)
    assert has_element?(ctx.view, "#new-track-prompt[phx-hook=SubmitOnEnter]")

    assert has_element?(
             ctx.view,
             ~s(#new-track-prompt[aria-label="What do you want to work on?"][placeholder="What do you want to work on?"])
           )

    ctx.view
    |> form("#new-track-form", new_track: %{prompt: "Fix the flaky login test"})
    |> render_submit()

    render_async(ctx.view, 1_000)
    assert_patch(ctx.view, "/p/#{ctx.project.id}/t/#{track.id}")

    assert [item] = Repo.all(PromptQueue.Item)
    assert {item.track_id, item.thread_id} == {track.id, track.id}
    assert {item.user_id, item.author_login} == {ctx.user.id, ctx.user.login}
    assert item.status == :queued

    child = find_live_child(ctx.view, "track-host")
    # As track_live_test's `settle/1`: shared CI load can exceed a short wait.
    render_async(child, 5_000)
    render_async(child, 5_000)
    assert has_element?(child, ".workspace-queue", "Fix the flaky login test")
    assert has_element?(child, ".workspace-queue .queue-state", "Queued")
    assert has_element?(child, "#track-setup-status", "Prompts will wait until setup is ready.")
  end

  test "an empty prompt creates the track exactly as before, with nothing queued", ctx do
    track = insert_track(project: ctx.project, conversation_id: "blank-conversation")
    reject(&Tracks.prompt/3)

    expect(Tracks, :open, fn _, _, attrs ->
      assert Map.keys(attrs) |> Enum.sort() == [:model, :origin, :runtime, :title, :visibility]
      assert %{title: "", origin: %{kind: "blank"}, visibility: "project"} = attrs

      {:ok, Tracks.present(track, role: :owner)}
    end)

    open_dialog(ctx.view)

    ctx.view
    |> form("#new-track-form", new_track: %{title: "", prompt: "  \n "})
    |> render_submit()

    render_async(ctx.view, 1_000)
    assert_patch(ctx.view, "/p/#{ctx.project.id}/t/#{track.id}")
    assert Repo.all(PromptQueue.Item) == []
  end

  test "a refused prompt still opens the track and says it was not queued", ctx do
    track = insert_track(project: ctx.project, conversation_id: "closed-conversation")
    expect(Tracks, :open, fn _, _, _ -> {:ok, Tracks.present(track, role: :owner)} end)

    expect(Tracks, :prompt, fn _, id, %{prompt: "Too late"} ->
      assert id == track.id
      {:error, {:conflict, "closed_track", "This track is closing or closed."}}
    end)

    open_dialog(ctx.view)
    ctx.view |> form("#new-track-form", new_track: %{prompt: "Too late"}) |> render_submit()
    html = render_async(ctx.view, 1_000)
    assert_patch(ctx.view, "/p/#{ctx.project.id}/t/#{track.id}")
    assert html =~ "The track opened, but its first prompt was not queued."
    assert html =~ "This track is closing or closed."
  end

  test "a revoked session cannot create a track or queue its prompt", ctx do
    reject(&Tracks.open/3)
    reject(&Tracks.prompt/3)
    open_dialog(ctx.view)
    Repo.delete!(ctx.session)
    :sys.replace_state(ctx.view.pid, &age_session_guard/1)

    assert {:error, {:redirect, %{to: "/login"}}} =
             ctx.view
             |> form("#new-track-form", new_track: %{prompt: "Run the migration"})
             |> render_submit()

    assert Repo.all(Track) == []
    assert Repo.all(PromptQueue.Item) == []
  end

  test "another user's project id is rejected and nothing is opened or queued", ctx do
    foreign = insert_project(user: insert_user(login: "elsewhere"))
    shared = insert_project(user: insert_user(login: "sharing-owner"))
    member = insert_project_member(shared, ctx.user)
    {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), "/p/#{shared.id}")
    render_async(view, 1_000)
    open_dialog(view)

    # The picker only offers the person's projects, and a forged id is ignored.
    refute has_element?(view, "#new-track-project option[value='#{foreign.id}']")
    render_hook(view, "new-track-project", %{project: foreign.id})
    assert has_element?(view, "#new-track-project option[value='#{shared.id}'][selected]")

    # Membership gone while the dialog is open, before any notice reaches the
    # page: the id it holds is someone else's project now, and the real
    # `Tracks.open/3` refuses it before any prompt is queued.
    reject(&Tracks.prompt/3)
    Repo.delete!(member)
    view |> form("#new-track-form", new_track: %{prompt: "Not mine"}) |> render_submit()
    assert render_async(view, 1_000) =~ "No such"
    assert has_element?(view, "#new-track-form")

    assert Repo.all(Track) == []
    assert Repo.all(PromptQueue.Item) == []
  end

  defp open_dialog(view) do
    render_click(view, "dialog", %{name: "new-track"})
    render_async(view, 1_000)
    assert has_element?(view, "#new-track-form")
  end

  defp stub_track_page do
    stub(Tracks, :get, fn _, id, _opts ->
      {:ok,
       %{
         track: Tracks.present(Repo.get!(Track, id), role: :owner),
         header: %Ravix.Tracks.Header{
           copy_of: nil,
           branched_from: nil,
           created: %{dir: "t", files: nil},
           has_setup_script: false
         },
         threads:
           Enum.map(
             Tracks.Store.threads_of(id),
             &%{id: &1.id, title: &1.title, runtime: &1.runtime, unread: false}
           ),
         starters: [],
         models: []
       }}
    end)

    stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _ -> :ok end)

    # The Files panel loads with the page; without this it would ask the
    # (fake-hosted) provider for a listing and wait on the network.
    stub(Tracks, :files, fn _, _, path ->
      {:ok, %Files.Listing{path: path || "/", truncated: false, entries: []}}
    end)
  end

  defp age_session_guard(state) do
    update_in(state.socket.assigns.session_guard, fn guard ->
      %{guard | verified_at_ms: guard.verified_at_ms - Guard.ttl_ms() - 1}
    end)
  end
end

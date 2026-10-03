defmodule RavixWeb.NewTrackChipsTest do
  @moduledoc """
  RAV-60: the New track dialog leads with its prompt and keeps every other
  choice in a chip — the repository (the RAV-10 list, in a popover), who can
  see the track, and the agent and model (the composer's menu). The chips
  are the same form: what they hold reaches `create-track` as the old
  controls' params did, and the server's checks are unchanged.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on, application-wide.
  """
  use RavixWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Ravix.Fountain.Client
  alias Ravix.{PromptQueue, Repo, Tracks}
  alias Ravix.Tracks.{Files, Track, Transcript}
  alias Ravix.Workspaces.Store

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    stub(Tracks, :list_many, fn user, ids, opts ->
      Map.new(ids, fn id ->
        {:ok, rows} = Tracks.list(user, id, opts)
        {id, rows}
      end)
    end)

    stub(Tracks, :open_options, fn _, _ ->
      {:ok,
       %{
         runtime: "claude",
         model: "anthropic/claude-opus-5",
         source: :project,
         owner_login: "me",
         owner?: true,
         runtimes: [
           %{
             runtime: "claude",
             connected: true,
             enabled: true,
             models: ["anthropic/claude-opus-5", "anthropic/claude-sonnet-5"]
           },
           %{runtime: "codex", connected: true, enabled: true, models: ["openai/gpt-5.5"]},
           %{runtime: "opencode", connected: false, enabled: true, models: []}
         ]
       }}
    end)

    user = insert_user(login: "me", credential_set_id: "set-me")
    {:ok, personal} = Store.ensure_personal_workspace(user)
    {:ok, user} = Ravix.Accounts.put_current_workspace(user, personal.id)
    alpha = insert_project(user: user, repo_full_name: "me/alpha")
    beta = insert_project(user: user, repo_full_name: "me/beta")
    scratch = insert_project(user: user, repo_full_name: nil, name: "Sandbox")
    insert_track(project: beta, created_by: user.id)

    %{
      user: user,
      conn: log_in_user(build_conn(), user),
      alpha: alpha,
      beta: beta,
      scratch: scratch
    }
  end

  defp open_dialog(conn) do
    {:ok, view, _} = live(conn, "/home")
    render_async(view)
    view |> element("#mobile-new-track") |> render_click()
    render_async(view)
    view
  end

  # Where the chips put what they hold: the form's own values, as a browser
  # would send them on submit.
  defp create_attrs(view, params) do
    test = self()

    expect(Tracks, :open, fn _user, id, attrs ->
      send(test, {:opened, id, attrs})
      {:error, {:conflict, "fixture", "Held for the test."}}
    end)

    view |> form("#new-track-form", new_track: params) |> render_submit()
    render_async(view)
    assert_received {:opened, id, attrs}
    {id, attrs}
  end

  defp change(view, field, params) do
    view
    |> form("#new-track-form", new_track: params)
    |> render_change(%{"_target" => ["new_track", field]})
  end

  test "picking a repository and then scratch in the popover moves the destination", ctx do
    view = open_dialog(ctx.conn)

    view |> element("#new-track-repo-menu #repo-option-#{ctx.alpha.id}") |> render_click()
    render_async(view)
    assert has_element?(view, "#new-track-repo-trigger", "me/alpha")
    assert has_element?(view, "#repo-option-#{ctx.alpha.id}[aria-pressed=true][data-chip-close]")

    view |> element("#new-track-repo-menu #repo-option-scratch") |> render_click()
    render_async(view)
    assert has_element?(view, "#new-track-repo-trigger", "Scratch · Sandbox")

    {id, attrs} = create_attrs(view, %{prompt: ""})
    assert id == ctx.scratch.id
    assert attrs.origin == %{kind: "blank"}
  end

  test "sharing and the agent and model chosen in the chips reach create", ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    view = open_dialog(ctx.conn)

    assert has_element?(view, "#new-track-sharing-trigger[aria-haspopup=dialog]", "Everyone")
    assert has_element?(view, ~s(#new-track-sharing-menu input[value=project][checked]))

    change(view, "visibility", %{visibility: "private"})
    assert has_element?(view, "#new-track-sharing-trigger", "Only me")

    # An agent that is not connected is offered, disabled, with the reason.
    assert has_element?(
             view,
             ~s(#new-track-model-menu input[name="new_track[runtime]"][value=opencode][disabled])
           )

    assert has_element?(view, "#new-track-model-menu", "Project default")

    change(view, "runtime", %{runtime: "codex"})
    assert has_element?(view, "#new-track-model-trigger", "Codex · GPT-5.5")

    assert has_element?(
             view,
             ~s(#new-track-model-menu input[name="new_track[model]"][value="openai/gpt-5.5"][checked])
           )

    change(view, "runtime", %{runtime: "claude"})
    change(view, "model", %{runtime: "claude", model: "anthropic/claude-sonnet-5"})
    assert has_element?(view, "#new-track-model-trigger", "Claude Sonnet 5")

    {id, attrs} = create_attrs(view, %{prompt: ""})
    assert id == ctx.beta.id

    assert %{visibility: "private", runtime: "claude", model: "anthropic/claude-sonnet-5"} =
             attrs

    assert :sys.get_state(view.pid).socket.assigns.track_form.params["preference_explicit"] ==
             "true"
  end

  test "with one way to share, the sharing chip is a label and still submits", ctx do
    view = open_dialog(ctx.conn)
    refute has_element?(view, "#new-track-sharing-trigger")
    assert has_element?(view, ".new-track-chips .pick-chip-static", "Everyone")
    {_id, attrs} = create_attrs(view, %{})
    assert attrs.visibility == "project"
  end

  test "creating with a prompt through the chips queues it on the new track", ctx do
    stub_track_page()

    track =
      insert_track(
        project: ctx.alpha,
        conversation_id: "first",
        created_by_login: ctx.user.login,
        setup_state: "pending"
      )

    view = open_dialog(ctx.conn)
    view |> element("#new-track-repo-menu #repo-option-#{ctx.alpha.id}") |> render_click()
    render_async(view)

    expect(Tracks, :open, fn user, id, attrs ->
      assert {user.id, id} == {ctx.user.id, ctx.alpha.id}
      assert %{runtime: "claude", model: "anthropic/claude-opus-5", visibility: "project"} = attrs
      {:ok, Tracks.present(track, role: :owner)}
    end)

    view
    |> form("#new-track-form", new_track: %{prompt: "Fix the flaky login test"})
    |> render_submit()

    render_async(view, 1_000)
    assert_patch(view, "/p/#{ctx.alpha.id}/t/#{track.id}")
    assert [%{status: :queued, track_id: track_id}] = Repo.all(PromptQueue.Item)
    assert track_id == track.id
  end

  test "creating without a prompt through the chips queues nothing", ctx do
    stub_track_page()
    track = insert_track(project: ctx.beta, conversation_id: "blank")
    reject(&Tracks.prompt/3)
    view = open_dialog(ctx.conn)

    expect(Tracks, :open, fn _, id, attrs ->
      assert id == ctx.beta.id
      assert Map.keys(attrs) |> Enum.sort() == [:model, :origin, :runtime, :title, :visibility]
      {:ok, Tracks.present(track, role: :owner)}
    end)

    view |> form("#new-track-form", new_track: %{prompt: ""}) |> render_submit()
    render_async(view, 1_000)
    assert_patch(view, "/p/#{ctx.beta.id}/t/#{track.id}")
    assert Repo.all(PromptQueue.Item) == []
  end

  test "the chips cannot carry a forged destination or agent past the server", ctx do
    foreign = insert_project(user: insert_user(login: "elsewhere"), repo_full_name: "x/y")
    view = open_dialog(ctx.conn)
    render_hook(view, "picker-pick", %{"project" => foreign.id})
    assert has_element?(view, "#new-track-repo-trigger", "me/beta")

    # A runtime the radios do not offer is still the server's to refuse.
    expect(Tracks, :open, fn _, id, %{runtime: "forged"} ->
      assert id == ctx.beta.id
      {:error, {:conflict, "invalid_runtime", "That agent isn't available."}}
    end)

    render_submit(view, "create-track", %{"new_track" => %{"runtime" => "forged"}})
    assert render_async(view) =~ "That agent isn&#39;t available."
    assert has_element?(view, "#new-track-form")
    assert Repo.all(Track) |> Enum.all?(&(&1.project_id in [ctx.beta.id]))
  end

  defp stub_track_page do
    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

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

    stub(Tracks, :files, fn _, _, path ->
      {:ok, %Files.Listing{path: path || "/", truncated: false, entries: []}}
    end)
  end
end

defmodule RavixWeb.FirstRunTest do
  # RAV-41: the first request, from wherever somebody with no work lands.
  # `/home` with nothing started and a project page with no tracks draw the
  # same first-prompt form as the walkthrough's last step
  # (`RavixWeb.Live.QuickStart`); starting opens a track with the prompt
  # queued on it and lands there, where setup's steps and the waiting prompt
  # are what they see.
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Accounts, Projects, PromptQueue, Repo, Tracks}
  alias Ravix.Accounts.User
  alias Ravix.Fountain.Client
  alias Ravix.Tracks.{Files, Track, Transcript}
  alias RavixWeb.Live.{Guard, QuickStart}

  setup :verify_on_exit!

  setup do
    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    stub(Accounts, :capabilities, fn -> %{github: true} end)
    # The rail from the database alone, and no provider health read: neither
    # is what these tests are about, and both would otherwise ask the
    # (unreachable) fake-hosted Fountain on every mount.
    stub(Tracks, :list_many, fn user, ids, opts ->
      Map.new(ids, fn id ->
        {:ok, rows} = Tracks.list(user, id, opts)
        {id, rows}
      end)
    end)

    stub(Projects, :agent_health, fn _, _ -> {:error, :not_asked} end)
    stub(Tracks, :agent_health, fn _, _, _ -> {:error, :not_asked} end)
    stub_track_page()
    :ok
  end

  defp user(attrs \\ []),
    do:
      insert_user(
        Keyword.merge(
          [agent: :claude, credential_kind: :subscription, credential_set_id: "set-1"],
          attrs
        )
      )

  defp repos(repos) do
    stub(Projects, :repos, fn _user, id ->
      {:ok, %{installations: [%{account: "acme", id: 42}], repos: repos, selected: id || 42}}
    end)
  end

  # The track `Tracks.open/3` answers with, as the real one would for this
  # project and person; the prompt is then queued by the real `Tracks.prompt/3`.
  defp opens(user, project) do
    track =
      insert_track(
        project: project,
        conversation_id: "first-#{System.unique_integer([:positive])}",
        created_by_login: user.login,
        setup_state: "pending"
      )

    expect(Tracks, :open, fn caller, id, attrs ->
      assert {caller.id, id} == {user.id, project.id}
      assert attrs == %{title: "", visibility: "project", origin: %{kind: "blank"}}
      {:ok, Tracks.present(track, role: :owner)}
    end)

    track
  end

  defp home(conn, user) do
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view, 1_000)
    render_async(view, 1_000)
    view
  end

  describe "/home with nothing started" do
    test "is the first-prompt form, with suggestions", %{conn: conn} do
      repos([%{full_name: "acme/app", installation_id: 42}])
      view = home(conn, user())

      assert has_element?(view, "#home-title", "Start your first track")
      refute has_element?(view, ".home-recent")
      # The only repository GitHub shows is already chosen, and named.
      assert has_element?(
               view,
               "#home-quick-start-target option[value='repo:acme/app'][selected]"
             )

      assert has_element?(view, "#home-quick-start-target option[value=scratch]")

      assert has_element?(
               view,
               "label[for=home-quick-start-prompt]",
               "What do you want to work on in acme/app?"
             )

      for suggestion <- QuickStart.suggestions() do
        view |> element("#home-start .quick-start-suggestion", suggestion) |> render_click()
        assert has_element?(view, "#home-quick-start-prompt", suggestion)
      end
    end

    test "Start creates the project and its track, queues the prompt and lands in the track",
         %{conn: conn} do
      user = user()
      repos([%{full_name: "acme/app", installation_id: 42}])
      view = home(conn, user)
      assert has_element?(view, "#home-start")

      # What `Projects.create/2` would have made, made after the page read
      # its rail: the task's own rail read is what lists it.
      project = insert_project(user: user, repo_full_name: "acme/app")
      track = opens(user, project)

      expect(Projects, :create, fn caller, attrs ->
        assert caller.id == user.id

        assert attrs == %{
                 "name" => "",
                 "repo" => "acme/app",
                 "installation_id" => 42,
                 "runtime" => "claude"
               }

        {:ok, Projects.present(project, :owner, Projects.Machine.none(), caller)}
      end)

      view
      |> form("#home-quick-start-form", quick_start: [prompt: "Add a health check"])
      |> render_submit()

      render_async(view, 1_000)
      assert_patch(view, "/p/#{project.id}/t/#{track.id}")

      assert [item] = Repo.all(PromptQueue.Item)
      assert {item.track_id, item.user_id, item.status} == {track.id, user.id, :queued}

      child = find_live_child(view, "track-host")
      render_async(child, 5_000)
      render_async(child, 5_000)
      assert has_element?(child, ".workspace-queue", "Add a health check")
      assert has_element?(child, ".workspace-queue", "Queued · starts when setup is ready")
      assert has_element?(child, "#track-setup-steps li", "Run setup")
      assert has_element?(child, "#track-setup-steps li[aria-current=step]")
    end

    test "somebody else's project cannot be named as the target", %{conn: conn} do
      repos([])
      foreign = insert_project(user: insert_user(login: "elsewhere"))
      reject(&Tracks.open/3)
      reject(&Projects.create/2)
      view = home(conn, user())

      render_submit(view, "quick-start", %{
        "quick_start" => %{"target" => "project:#{foreign.id}", "prompt" => "Not mine"}
      })

      assert has_element?(view, "#home-start", "Choose a repository from the list")
      assert Repo.all(PromptQueue.Item) == []
    end

    test "a revoked session starts nothing", %{conn: conn} do
      repos([%{full_name: "acme/app", installation_id: 42}])
      reject(&Projects.create/2)
      reject(&Tracks.open/3)
      {token, session} = insert_session(user())
      conn = Plug.Test.init_test_session(conn, session_token: token)
      {:ok, view, _} = live(conn, "/home")
      render_async(view, 1_000)
      render_async(view, 1_000)

      Repo.delete!(session)
      :sys.replace_state(view.pid, &age_session_guard/1)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#home-quick-start-form", quick_start: [prompt: "Run the migration"])
               |> render_submit()

      assert Repo.all(Track) == []
      assert Repo.all(PromptQueue.Item) == []
    end

    test "somebody with a project gets their recent tracks instead", %{conn: conn} do
      user = user()
      project = insert_project(user: user, name: "Busy")
      track = insert_track(project: project, created_by_login: user.login)
      reject(&Projects.repos/2)
      view = home(conn, user)

      refute has_element?(view, "#home-start")
      assert has_element?(view, "#home-title", "Home")
      assert has_element?(view, ".home-recent a[href='/p/#{project.id}/t/#{track.id}']", "Busy")
    end
  end

  describe "skipping setup" do
    test "lands on /home's first-prompt form", %{conn: conn} do
      repos([])
      user = user(onboarded_at: nil)
      conn = log_in_user(conn, user)
      {:ok, welcome, _} = live(conn, "/welcome/agent")
      welcome |> element("#welcome-skip") |> render_click()
      assert_redirect(welcome, "/home")

      view = home(conn, user)
      assert has_element?(view, "#home-start")
      assert has_element?(view, "#home-quick-start-target option[value=scratch][selected]")
    end

    test "is never forced on somebody who already has a project", %{conn: conn} do
      user = user(onboarded_at: nil)
      project = insert_project(user: user)
      insert_track(project: project)
      reject(&Projects.repos/2)

      for path <- ["/", "/home", "/inbox"] do
        assert {:ok, view, _} = live(log_in_user(conn, user), path)
        render_async(view, 1_000)
        assert Repo.get!(User, user.id).onboarded_at == nil
        assert has_element?(view, "#workspace-stage")
      end
    end
  end

  describe "a project page with no track open" do
    test "with no tracks yet asks what to work on in its repository", %{conn: conn} do
      user = user()
      project = insert_project(user: user, repo_full_name: "acme/site")
      reject(&Projects.create/2)
      {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
      render_async(view, 1_000)
      track = opens(user, project)

      assert has_element?(
               view,
               "label[for=project-quick-start-prompt]",
               "What do you want to work on in acme/site?"
             )

      # The project is the target, not a choice, and not the agent either.
      refute has_element?(view, "#project-quick-start-target")
      refute has_element?(view, "#project-quick-start-runtime")
      assert has_element?(view, "#project-explainer a[href='/welcome?from=start']")

      view
      |> element("#project-start .quick-start-suggestion", "Find and fix one small bug")
      |> render_click()

      assert has_element?(view, "#project-quick-start-prompt", "Find and fix one small bug")
      view |> form("#project-quick-start-form") |> render_submit()
      render_async(view, 1_000)
      assert_patch(view, "/p/#{project.id}/t/#{track.id}")
      assert [%{track_id: track_id}] = Repo.all(PromptQueue.Item)
      assert track_id == track.id
    end

    test "with tracks lists the recent ones instead", %{conn: conn} do
      user = user()
      project = insert_project(user: user)
      track = insert_track(project: project, title: "Search the projects page")
      {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
      render_async(view, 1_000)

      refute has_element?(view, "#project-quick-start")

      assert has_element?(
               view,
               "#project-start a[href='/p/#{project.id}/t/#{track.id}']",
               "Search the projects page"
             )
    end

    test "a project removed from under the page refuses the start", %{conn: conn} do
      owner = insert_user(login: "sharing-owner")
      project = insert_project(user: owner)
      user = user()
      member = insert_project_member(project, user)
      reject(&Tracks.prompt/3)
      {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
      render_async(view, 1_000)
      assert has_element?(view, "#project-quick-start")

      # Membership gone before any notice reaches the page: the real
      # `Tracks.open/3` asks again and refuses.
      Repo.delete!(member)

      view
      |> form("#project-quick-start-form", quick_start: [prompt: "Not mine"])
      |> render_submit()

      assert render_async(view, 1_000) =~ "No such"
      assert Repo.all(Track) == []
      assert Repo.all(PromptQueue.Item) == []
    end
  end

  describe "setup steps" do
    test "say how long setup took once it has (RAV-132)" do
      at = fn seconds -> DateTime.add(~U[2026-10-01 12:00:00Z], seconds, :second) end
      duration = &RavixWeb.TrackLive.setup_duration(%{created_at: at.(0), opened_at: at.(&1)})

      assert duration.(42) == "42s"
      assert duration.(60) == "1m"
      assert duration.(72) == "1m 12s"
      assert duration.(-1) == nil
      assert RavixWeb.TrackLive.setup_duration(%{created_at: at.(0), opened_at: nil}) == nil
    end

    test "name each step, mark the one under way and those done" do
      project = %{repo: "acme/app"}

      steps = fn stage, state ->
        RavixWeb.TrackLive.setup_steps(
          %{sandbox_stage: stage, setup_state: state, sandbox_layout: :dedicated},
          project
        )
        |> Enum.map(& &1.state)
      end

      assert steps.("creating", "pending") == [:now, :todo, :todo, :todo]
      assert steps.("cloning", "running") == [:done, :now, :todo, :todo]
      assert steps.("setup", "running") == [:done, :done, :now, :todo]
      assert steps.(nil, "pending") == [:done, :now, :todo, :todo]
      assert steps.(nil, "failed") == [:done, :done, :failed, :todo]
      assert steps.(nil, "ready") == [:done, :done, :done, :now]

      # RAV-132: once setup is ready the last step is the first prompt's
      # hand-off, which the page says the state of itself.
      handoff = fn state ->
        RavixWeb.TrackLive.setup_steps(
          %{sandbox_stage: nil, setup_state: "ready", sandbox_layout: :dedicated},
          project,
          state
        )
        |> Enum.map(& &1.state)
      end

      assert handoff.(:now) == [:done, :done, :done, :now]
      assert handoff.(:done) == [:done, :done, :done, :done]
      assert handoff.(:skipped) == [:done, :done, :done, :skipped]
      assert handoff.(:failed) == [:done, :done, :done, :failed]

      assert [%{label: "Start this track's machine"}, %{label: "Check out acme/app" <> _} | _] =
               RavixWeb.TrackLive.setup_steps(
                 %{sandbox_stage: nil, setup_state: "pending", sandbox_layout: :dedicated},
                 project
               )

      assert [%{label: "Wake the project machine"}, %{label: "Make a new branch"} | _] =
               RavixWeb.TrackLive.setup_steps(
                 %{sandbox_stage: nil, setup_state: "pending", sandbox_layout: :shared},
                 %{repo: nil}
               )
    end
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

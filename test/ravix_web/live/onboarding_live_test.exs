defmodule RavixWeb.OnboardingLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Accounts, Crypto, Projects, PromptQueue, Repo, Tracks}
  alias Ravix.Accounts.{Inference, User}
  alias Ravix.Fountain.{Client, FakeTransport}
  alias Ravix.Projects.Machine
  alias Ravix.Tracks.Track
  alias RavixWeb.Live.{Guard, QuickStart}

  @sets "/api/account/inference-credential-sets"

  setup :verify_on_exit!

  setup do
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude, :codex]} end)
    :ok
  end

  test "each onboarding step has a title on arrival and navigation", %{conn: conn} do
    github([])
    conn = log_in_user(conn, fresh())
    {:ok, view, _} = live(conn, "/welcome")

    for {path, title, heading} <- [
          {"/welcome", "Welcome", "Welcome"},
          {"/welcome/agent", "Connect your agent", "Connect your agent"},
          {"/welcome/github", "Connect GitHub", "Connect GitHub"},
          {"/welcome/project", "Start your first track", "What do you want to work on?"}
        ] do
      {:ok, direct, _} = live(conn, path)
      assert page_title(direct) == title <> " · Ravix"
      assert has_element?(direct, "h1", heading)

      if path == "/welcome/project" do
        assert has_element?(direct, "#welcome-project", "Ravix builds its machine")
      end

      render_patch(view, path)
      render_async(view)
      assert page_title(view) == title <> " · Ravix"
    end
  end

  defp fresh(attrs \\ []), do: insert_user(Keyword.merge([onboarded_at: nil], attrs))

  defp connected(attrs \\ []) do
    fresh(
      Keyword.merge(
        [agent: :claude, credential_kind: :subscription, credential_set_id: "set-1"],
        attrs
      )
    )
  end

  defp github(installations, repos \\ []) do
    stub(Accounts, :capabilities, fn -> %{github: true} end)

    stub(Projects, :repos, fn _user, id ->
      {:ok, %{installations: installations, repos: repos, selected: id || 42}}
    end)
  end

  # What waiting out `Guard.ttl_ms/0` amounts to; see the same helper in
  # `RavixWeb.WorkspaceLiveTest`.
  defp age_session_guard(state) do
    update_in(state.socket.assigns.session_guard, fn guard ->
      %{guard | verified_at_ms: guard.verified_at_ms - Guard.ttl_ms() - 1}
    end)
  end

  describe "who is sent here" do
    test "a first visit lands on the walkthrough from each place nobody chose to be", %{
      conn: conn
    } do
      conn = log_in_user(conn, fresh())

      for path <- ["/", "/home", "/inbox"] do
        assert {:ok, view, _} = live(conn, path)
        assert_redirect(view, "/welcome")
      end
    end

    test "somebody who finished it, or skipped it, is left in the workspace", %{conn: conn} do
      assert {:ok, _view, html} = live(log_in_user(conn, insert_user()), "/")
      assert html =~ "Inbox"
    end

    test "somebody invited into a project before their first visit goes to it, not to a tour", %{
      conn: conn
    } do
      guest = fresh()
      project = insert_project()
      insert_project_member(project, guest)

      assert {:ok, _view, _html} = live(log_in_user(conn, guest), "/")
      assert {:ok, _view, _html} = live(log_in_user(conn, guest), "/p/#{project.id}")
    end

    test "a stranger is sent to sign in", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, "/welcome/agent")
    end
  end

  describe "how it works" do
    test "walks through describing a change, reviewing it, and a shared thread", %{
      conn: conn
    } do
      {:ok, view, html} = live(log_in_user(conn, fresh()), "/welcome")

      assert html =~ "Describe a change. Ravix opens a branch, and your agent starts there."
      assert html =~ "You describe the task. Ravix opens a branch, and the agent starts there."

      assert html =~
               "The diff sits next to the conversation. The preview is the app, already running."

      assert html =~
               "Share the track. They continue the thread, with the earlier decisions still there."

      # The section the stylesheet draws (and the browser suite checks) is the
      # one the page renders: three numbered steps, the first open.
      assert has_element?(view, "section#welcome-workflow.workflow-preview")

      assert has_element?(
               view,
               "#welcome-workflow details.workflow-step[open]",
               "Describe the change"
             )

      assert view
             |> element("#welcome-workflow")
             |> render()
             |> then(&(length(String.split(&1, "workflow-num")) - 1)) == 3

      assert view |> element("#welcome-start") |> render_click()
      assert_patch(view, "/welcome/agent")
    end

    test "coming back part way through carries on rather than starting over", %{conn: conn} do
      github([])

      assert {:error, {:live_redirect, %{to: "/welcome/github"}}} =
               live(log_in_user(conn, connected()), "/welcome")
    end

    test "but the introduction can still be read again on purpose", %{conn: conn} do
      {:ok, _view, html} = live(log_in_user(conn, connected()), "/welcome?from=start")
      assert html =~ "Describe a change. Ravix opens a branch, and your agent starts there."
    end
  end

  defp linking(enabled? \\ true, pending \\ nil),
    do:
      stub(Inference, :link_status, fn _user -> {:ok, %{enabled?: enabled?, pending: pending}} end)

  defp chatgpt_link(fields \\ []) do
    struct!(
      %Inference.Link{
        attempt_id: "att-1",
        set_id: "set-1",
        user_code: "ABCD-EFGH",
        verification_url: "https://auth.openai.com/codex/device",
        trusted?: true,
        poll_interval: 1
      },
      fields
    )
  end

  describe "choosing an agent" do
    test "both agents offer a subscription or a key; Codex's subscription is a sign-in, not a paste",
         %{
           conn: conn
         } do
      linking()
      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/agent")
      refute has_element?(view, "#credential-form")

      html = view |> element("#agent-claude") |> render_click()
      assert html =~ "claude setup-token"
      assert has_element?(view, "#kind-subscription[aria-pressed=true]")
      assert has_element?(view, "#kind-api_key")

      html = view |> element("#kind-api_key") |> render_click()
      assert html =~ "Anthropic Console"

      html = view |> element("#agent-codex") |> render_click()
      assert html =~ "OpenAI platform"
      assert has_element?(view, "#kind-api_key[aria-pressed=true]")
      assert has_element?(view, "#credential-form")

      html = view |> element("#kind-subscription") |> render_click()
      assert html =~ "Connect ChatGPT"
      assert has_element?(view, "#chatgpt-connect")
      refute has_element?(view, "#credential-form")
    end

    test "connecting the first agent makes it the default and offers Continue", %{conn: conn} do
      user = fresh()
      github([])
      assert user.agent == nil

      # `Inference.connect/2` itself, against a scripted Fountain: the first
      # connection is the default because the context says so, not the page.
      client =
        FakeTransport.client([
          {%{method: "GET", path: @sets}, {200, [], %{data: [%{id: "house", is_default: true}]}}},
          {%{method: "POST", path: @sets, body: %{name: "ravix:#{user.id}"}},
           {201, [], %{data: %{id: "mine"}}}},
          {%{method: "PUT", path: "#{@sets}/mine/credentials/claude_code_oauth_token"},
           {200, [], %{data: %{set: true}}}}
        ])

      stub(Ravix.Fountain, :client, fn -> client end)
      stub(Inference, :subscription, fn _ -> {:ok, nil} end)
      stub(Ravix.MachineCache, :catalog, fn _ -> {:error, :not_asked} end)

      stub(Inference, :held, fn user ->
        {:ok, if(user.agent, do: [{user.agent, :subscription}], else: [])}
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/welcome/agent")
      render_async(view)

      # One decision: two cards, each with Connect, and nothing else in view.
      assert has_element?(view, "#agent-card-claude button#agent-claude", "Connect")
      assert has_element?(view, "#agent-card-codex button#agent-codex", "Connect")
      assert has_element?(view, "#agent-later", "I'll do this later")
      refute has_element?(view, "#credential-form")

      view |> element("#agent-claude") |> render_click()
      assert render(view) =~ "claude setup-token"
      refute has_element?(view, "#agent-claude")

      view
      |> form("#credential-form", credential: [value: "sk-ant-oat01-private"])
      |> render_submit()

      refute render(view) =~ "sk-ant-oat01-private"
      render_async(view)
      render_async(view)

      assert %User{agent: :claude, credential_kind: :subscription, credential_set_id: "mine"} =
               Repo.get!(User, user.id)

      assert has_element?(view, "#agent-claude-status", "Connected")
      assert has_element?(view, "#agent-claude-status .chip", "Default for new projects")
      assert has_element?(view, "#agent-card-codex button#agent-codex", "Connect")
      refute has_element?(view, "#credential-form")
      refute has_element?(view, "#second-agent-nudge")

      view |> element("#agent-later", "Continue") |> render_click()
      assert_patch(view, "/welcome/github")
      refute render(view) =~ "sk-ant-oat01-private"
    end

    test "Manage reveals the default, what is held with its Remove, and API keys", %{conn: conn} do
      stub(Inference, :held, fn _ -> {:ok, [{:claude, :subscription}, {:codex, :api_key}]} end)
      stub(Inference, :subscription, fn _ -> {:ok, nil} end)
      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/agent")
      render_async(view)

      assert has_element?(view, "#agent-manage-toggle[aria-expanded=false]")
      assert has_element?(view, "#agent-manage[hidden]")
      assert has_element?(view, "#agent-manage #remove-claude-subscription")
      assert has_element?(view, "#agent-manage #make-default-codex")
      assert has_element?(view, "#agent-manage #kind-api_key")

      view |> element("#agent-manage-toggle") |> render_click()
      assert has_element?(view, "#agent-manage-toggle[aria-expanded=true]")
      refute has_element?(view, "#agent-manage[hidden]")

      # The API key is there to choose, and choosing it shows its steps.
      view |> element("#kind-api_key") |> render_click()
      assert render(view) =~ "Anthropic Console"
      assert has_element?(view, "#credential-form label", "API key")

      view |> element("#agent-manage-toggle") |> render_click()
      assert has_element?(view, "#agent-manage[hidden]")
    end

    test "a refusal lands on the field, the value is not given back, and the button works again",
         %{conn: conn} do
      expect(Inference, :connect, fn _user, _attrs ->
        {:error, {:unprocessable, "bad_credential", "Anthropic did not accept that."}}
      end)

      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/agent")
      view |> element("#agent-claude") |> render_click()
      view |> form("#credential-form", credential: [value: "sk-ant-WRONG"]) |> render_submit()

      html = render_async(view)
      assert html =~ "Anthropic did not accept that."
      refute html =~ "sk-ant-WRONG"
      refute has_element?(view, "#credential-form button[disabled]")
    end

    test "a word the form never offered names no agent and no atom", %{conn: conn} do
      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/agent")

      panel = with_target(view, "#agent-panel")
      render_click(panel, "choose-agent", %{agent: "gemini"})
      render_click(panel, "choose-kind", %{kind: "gift_card"})
      refute has_element?(view, "#credential-form")
      refute has_element?(view, "[aria-pressed=true]")
    end

    test "somebody already connected is told so, and what replacing it means", %{conn: conn} do
      stub(Inference, :held, fn _ -> {:ok, [{:claude, :subscription}]} end)
      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/agent")
      render_async(view)
      assert has_element?(view, "#agent-claude-status", "Connected")
      # Replacing it is under Manage, as the kind it is paid with.
      view |> element("#kind-subscription") |> render_click()
      html = render_async(view)
      assert html =~ "Claude Code is connected with your subscription"
      assert html =~ "open tracks"
    end

    test "removing what is connected stays on the step, with the form ready for what comes next",
         %{conn: conn} do
      user = connected()

      stub(Inference, :held, fn
        %User{credential_kind: :subscription} -> {:ok, [{:claude, :subscription}]}
        %User{credential_kind: nil} -> {:ok, []}
      end)

      expect(Inference, :disconnect, fn caller, :claude, :subscription ->
        Accounts.save_setup(caller, %{credential_kind: nil})
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/welcome/agent")
      render_async(view)
      view |> element("#remove-claude-subscription") |> render_click()
      view |> element("#confirm-agent-disconnect") |> render_click()
      html = render_async(view)

      refute html =~ "Claude Code is connected with your subscription"
      assert has_element?(view, "#credential-form")
      refute has_element?(view, "#held-missing")
      assert %User{credential_kind: nil} = Repo.get!(User, user.id)
    end
  end

  describe "connecting ChatGPT" do
    test "shows the code Fountain gave, polls until ChatGPT approves it, then moves on", %{
      conn: conn
    } do
      user = fresh()
      github([])
      linking()
      {:ok, polls} = Agent.start_link(fn -> 0 end)
      test = self()

      expect(Inference, :begin_link, fn caller ->
        assert caller.id == user.id
        {:ok, chatgpt_link()}
      end)

      stub(Inference, :poll_link, fn caller, %Inference.Link{attempt_id: "att-1"} ->
        assert caller.id == user.id
        poll = Agent.get_and_update(polls, &{&1 + 1, &1 + 1})
        send(test, {:polled, poll})

        case poll do
          1 ->
            {:ok, :pending}

          _ ->
            Accounts.save_setup(caller, %{
              agent: :codex,
              credential_kind: :subscription,
              credential_set_id: "set-1"
            })
        end
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/welcome/agent")
      view |> element("#agent-codex") |> render_click()
      view |> element("#kind-subscription") |> render_click()

      html = view |> element("#chatgpt-connect") |> render_click()
      assert html =~ "Asking ChatGPT"

      html = render_async(view)
      assert html =~ "ABCD-EFGH"

      assert has_element?(
               view,
               ~s(#chatgpt-verification[href="https://auth.openai.com/codex/device"])
             )

      assert html =~
               "Only type it if you started this sign-in yourself, on this page, just now."

      refute has_element?(view, "#chatgpt-connect")

      # The page ticks itself; here the ticks are sent by hand so the test
      # does not wait out the interval. Each tick reaches the panel through
      # `send_update/2`, one hop behind the message, so the poll is not pending
      # when `render_async/1` asked straight away looks; the poll's own call is
      # what says it is, and is waited for before the render.
      send(view.pid, {:agent_panel, "agent-panel", :poll_link})
      assert_receive {:polled, 1}
      html = render_async(view)
      assert html =~ "ABCD-EFGH"

      send(view.pid, {:agent_panel, "agent-panel", :poll_link})
      assert_receive {:polled, 2}
      render_async(view)
      assert has_element?(view, "#welcome-agent")
      view |> element("#agent-later") |> render_click()
      assert_patch(view, "/welcome/github")
      assert %User{agent: :codex, credential_kind: :subscription} = Repo.get!(User, user.id)
    end

    test "a sign-in that ends badly says why, and the button comes back", %{conn: conn} do
      linking()
      expect(Inference, :begin_link, fn _user -> {:ok, chatgpt_link()} end)
      test = self()

      expect(Inference, :poll_link, fn _user, _link ->
        send(test, :polled)
        {:error, {:unprocessable, "link_failed", "ChatGPT refused the code."}}
      end)

      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/agent")
      view |> element("#agent-codex") |> render_click()
      view |> element("#kind-subscription") |> render_click()
      view |> element("#chatgpt-connect") |> render_click()
      render_async(view)

      # The tick reaches the panel through `send_update/2`, one hop behind the
      # message itself, so `render_async/1` asked straight away finds no poll
      # pending yet and renders the code. The poll's own call is the moment it
      # is pending, which is what to wait for.
      send(view.pid, {:agent_panel, "agent-panel", :poll_link})
      assert_receive :polled
      html = render_async(view)
      assert html =~ "ChatGPT refused the code."
      refute html =~ "ABCD-EFGH"
      assert has_element?(view, "#chatgpt-connect")
    end

    test "a refusal to start one is said in place, and a page Fountain did not vouch for is not a link",
         %{conn: conn} do
      linking()

      expect(Inference, :begin_link, fn _user ->
        {:error, {:unavailable, "Too many ChatGPT sign-ins were started."}}
      end)

      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/agent")
      view |> element("#agent-codex") |> render_click()
      view |> element("#kind-subscription") |> render_click()
      view |> element("#chatgpt-connect") |> render_click()
      html = render_async(view)
      assert html =~ "Too many ChatGPT sign-ins were started."
      assert has_element?(view, "#chatgpt-connect")

      expect(Inference, :begin_link, fn _user ->
        {:ok, chatgpt_link(verification_url: "http://not-openai.example/device", trusted?: false)}
      end)

      view |> element("#chatgpt-connect") |> render_click()
      html = render_async(view)
      assert html =~ "not-openai.example/device"
      refute has_element?(view, "a#chatgpt-verification")
      assert has_element?(view, "code#chatgpt-verification")
    end

    test "a sign-in already open is picked up on arrival rather than started again", %{
      conn: conn
    } do
      linking(true, chatgpt_link(user_code: "WXYZ-1234"))
      reject(&Inference.begin_link/1)
      stub(Inference, :poll_link, fn _user, _link -> {:ok, :pending} end)

      {:ok, view, _} =
        live(
          log_in_user(conn, fresh(agent: :codex, credential_kind: :subscription)),
          "/welcome/agent"
        )

      html = render_async(view)
      assert html =~ "WXYZ-1234"
      refute has_element?(view, "#chatgpt-connect")
    end

    test "cancelling forgets the code at once and tells Fountain", %{conn: conn} do
      linking()
      expect(Inference, :begin_link, fn _user -> {:ok, chatgpt_link()} end)
      expect(Inference, :cancel_link, fn _user, %Inference.Link{attempt_id: "att-1"} -> :ok end)
      reject(&Inference.poll_link/2)

      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/agent")
      view |> element("#agent-codex") |> render_click()
      view |> element("#kind-subscription") |> render_click()
      view |> element("#chatgpt-connect") |> render_click()
      assert render_async(view) =~ "ABCD-EFGH"

      html = view |> element("#chatgpt-cancel") |> render_click()
      refute html =~ "ABCD-EFGH"
      render_async(view)
      # The tick the page scheduled for the cancelled sign-in polls nothing.
      send(view.pid, {:agent_panel, "agent-panel", :poll_link})
      assert has_element?(view, "#chatgpt-connect")
    end

    test "a Fountain where nobody may link says so instead of offering the button", %{conn: conn} do
      linking(false)
      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/agent")
      view |> element("#agent-codex") |> render_click()
      view |> element("#kind-subscription") |> render_click()
      html = render_async(view)
      assert html =~ "not switched on"
      refute has_element?(view, "#chatgpt-connect")
      assert has_element?(view, "#kind-api_key")
    end

    test "somebody connected this way is told, and that reconnecting ends open tracks", %{
      conn: conn
    } do
      linking()

      stub(Inference, :held, fn _ -> {:ok, [{:codex, :subscription}]} end)

      {:ok, view, _} =
        live(log_in_user(conn, connected(agent: :codex)), "/welcome/agent")

      render_async(view)
      view |> element("#kind-subscription") |> render_click()
      html = render_async(view)
      assert html =~ "Codex is connected with your ChatGPT subscription"
      assert html =~ "Sign in again to reconnect it"
      assert html =~ "open tracks"
    end

    test "a session that went without notice stops the polling with the page", %{conn: conn} do
      linking()
      expect(Inference, :begin_link, fn _user -> {:ok, chatgpt_link()} end)
      reject(&Inference.poll_link/2)
      {token, session} = insert_session(fresh())
      conn = Plug.Test.init_test_session(conn, session_token: token)
      {:ok, view, _} = live(conn, "/welcome/agent")
      view |> element("#agent-codex") |> render_click()
      view |> element("#kind-subscription") |> render_click()
      view |> element("#chatgpt-connect") |> render_click()
      assert render_async(view) =~ "ABCD-EFGH"

      Repo.delete!(session)
      :sys.replace_state(view.pid, &age_session_guard/1)

      send(view.pid, {:agent_panel, "agent-panel", :poll_link})
      assert_redirect(view, "/login")
    end
  end

  describe "connecting GitHub" do
    test "nothing installed offers the install, which is the server's redirect and not a built URL",
         %{conn: conn} do
      github([])
      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/github")
      render_async(view)

      assert has_element?(view, "#github-none a[href='/api/auth/install']")
      assert view |> element("#github-continue") |> render() =~ "Continue without GitHub"
    end

    test "an installation says whose, and continues", %{conn: conn} do
      github([%{account: "acme", id: 42}])
      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/github")

      assert render_async(view) =~ "Connected to acme."
      view |> element("#github-continue") |> render_click()
      assert_patch(view, "/welcome/project")
    end

    test "a GitHub that cannot be read is drawn as none, not as a crash", %{conn: conn} do
      stub(Accounts, :capabilities, fn -> %{github: true} end)
      stub(Projects, :repos, fn _user, _id -> {:error, {:reauthenticate, "Sign in again."}} end)

      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/github")
      render_async(view)
      assert has_element?(view, "#github-none")
    end
  end

  describe "the first prompt" do
    setup do
      stub(Ravix.Fountain, :client, fn ->
        Client.new("https://fountain.test", "key")
      end)

      :ok
    end

    # A project and its track as the contexts would answer, so the prompt is
    # queued by the real `Tracks.prompt/3` on a real row.
    defp opens_on(user, project_attrs \\ []) do
      project = insert_project(Keyword.merge([user: user], project_attrs))
      track = insert_track(project: project, conversation_id: "first", setup_state: "pending")

      expect(Tracks, :open, fn caller, id, attrs ->
        assert {caller.id, id} == {user.id, project.id}
        assert attrs == %{title: "", visibility: "project", origin: %{kind: "blank"}}
        {:ok, Tracks.present(track, role: :owner)}
      end)

      {project, track}
    end

    test "creates the project and its first track, queues the prompt, and lands in the track",
         %{conn: conn} do
      user = connected()
      # Exactly one repository: it is already chosen.
      github([%{account: "acme", id: 42}], [%{full_name: "acme/app", installation_id: 42}])
      {project, track} = opens_on(user)

      expect(Projects, :create, fn caller, attrs ->
        assert caller.id == user.id

        assert attrs == %{
                 "name" => "",
                 "repo" => "acme/app",
                 "installation_id" => 42,
                 "runtime" => "claude"
               }

        {:ok, Projects.present(project, :owner, Machine.none(), caller)}
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/welcome/project")
      render_async(view)

      assert has_element?(view, "#first-prompt-target option[value='repo:acme/app'][selected]")
      assert has_element?(view, "#first-prompt-target option[value=scratch]")

      assert has_element?(
               view,
               "label[for=first-prompt-prompt]",
               "What do you want to work on in acme/app?"
             )

      # The agent is the default from the step before, as a chip, not a question.
      assert has_element?(view, "#first-prompt-runtime option[value=claude][selected]")
      refute has_element?(view, "#project-runtime")

      view
      |> form("#first-prompt-form", quick_start: [prompt: "Add a health check endpoint"])
      |> render_submit()

      assert_redirect(view, "/p/#{project.id}/t/#{track.id}", 1_000)
      assert %User{onboarded_at: %DateTime{}} = Repo.get!(User, user.id)

      assert [item] = Repo.all(PromptQueue.Item)
      assert {item.track_id, item.user_id, item.status} == {track.id, user.id, :queued}
    end

    test "the suggested prompts fill the composer", %{conn: conn} do
      github([])
      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/project")
      render_async(view)

      for suggestion <- QuickStart.suggestions() do
        view |> element(".quick-start-suggestion", suggestion) |> render_click()
        assert has_element?(view, "#first-prompt-prompt", suggestion)
      end

      # Only what was offered fills it.
      render_click(view, "quick-start-suggest", %{"prompt" => "rm -rf /"})
      refute render(view) =~ "rm -rf /"
    end

    test "with more than one repository nothing is chosen for them", %{conn: conn} do
      github([%{account: "acme", id: 42}], [
        %{full_name: "acme/app", installation_id: 42},
        %{full_name: "acme/api", installation_id: 42}
      ])

      reject(&Projects.create/2)
      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/project")
      render_async(view)
      refute has_element?(view, "#first-prompt-target option[selected]")

      view |> form("#first-prompt-form", quick_start: [prompt: "Tidy up"]) |> render_submit()
      assert render(view) =~ "Choose a repository, or No repository."
    end

    test "a repository the list never offered is not sent as one", %{conn: conn} do
      github([%{account: "acme", id: 42}], [%{full_name: "acme/app", installation_id: 42}])
      reject(&Projects.create/2)

      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/project")
      render_async(view)

      render_submit(view, "quick-start", %{
        "quick_start" => %{"target" => "repo:someone-elses/private", "prompt" => "Mine now"}
      })

      assert render(view) =~ "Choose a repository from the list"

      render_submit(view, "quick-start", %{
        "quick_start" => %{"target" => "project:#{insert_project().id}", "prompt" => "Mine now"}
      })

      assert render(view) =~ "Choose a repository from the list"
      refute has_element?(view, "#first-prompt-submit[disabled]")
    end

    test "an empty prompt is refused on the field and nothing is created", %{conn: conn} do
      github([])
      reject(&Projects.create/2)
      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/project")
      render_async(view)

      view |> form("#first-prompt-form", quick_start: [prompt: "  "]) |> render_submit()
      assert has_element?(view, "#first-prompt", "Say what you want to work on.")
    end

    test "a deployment with no GitHub App starts a scratch machine named for the prompt", %{
      conn: conn
    } do
      user = connected()
      stub(Accounts, :capabilities, fn -> %{github: false} end)
      reject(&Projects.repos/2)
      {project, track} = opens_on(user, repo_full_name: nil)

      expect(Projects, :create, fn _caller, attrs ->
        assert attrs == %{"name" => "Explain how this codebase is", "runtime" => "codex"}
        {:ok, Projects.present(project, :owner, Machine.none(), user)}
      end)

      {:ok, view, html} = live(log_in_user(conn, user), "/welcome/github")
      assert html =~ "GitHub is not configured for this deployment"

      view |> element("#github-continue") |> render_click()
      assert_patch(view, "/welcome/project")
      assert has_element?(view, "#first-prompt-target option[value=scratch][selected]")

      view |> element(".quick-start-suggestion", "Explain how this codebase") |> render_click()

      view
      |> form("#first-prompt-form", quick_start: [runtime: "codex"])
      |> render_submit()

      assert_redirect(view, "/p/#{project.id}/t/#{track.id}", 1_000)
    end

    test "a project whose track could not open is still where they land, with the reason", %{
      conn: conn
    } do
      user = connected()
      github([])
      project = insert_project(user: user, repo_full_name: nil)

      expect(Projects, :create, fn _, _ ->
        {:ok, Projects.present(project, :owner, Machine.none(), user)}
      end)

      expect(Tracks, :open, fn _, _, _ ->
        {:error, {:conflict, "machine_busy", "The machine is busy."}}
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/welcome/project")
      render_async(view)
      view |> form("#first-prompt-form", quick_start: [prompt: "Go"]) |> render_submit()

      {path, flash} = assert_redirect(view, 1_000)
      assert path == "/p/#{project.id}"
      assert flash["error"] =~ "The machine is busy."
      assert Repo.all(PromptQueue.Item) == []
    end

    test "choosing another GitHub account re-reads the repositories for that one", %{conn: conn} do
      test_pid = self()
      stub(Accounts, :capabilities, fn -> %{github: true} end)

      stub(Projects, :repos, fn _user, id ->
        send(test_pid, {:repos_for, id})

        {:ok,
         %{
           installations: [%{account: "acme", id: 42}, %{account: "other", id: 7}],
           repos: [%{full_name: "#{id || 42}/app", installation_id: id || 42}],
           selected: id || 42
         }}
      end)

      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/project")
      render_async(view)
      assert_received {:repos_for, nil}

      render_change(view, "installation", %{installation: "7"})
      assert render_async(view) =~ "7/app"
      assert_received {:repos_for, 7}

      # Not a number: nothing is read and nothing changes.
      render_change(view, "installation", %{installation: "7; drop"})
      refute_received {:repos_for, _}
    end

    test "what was typed survives the form being edited, and a task that dies says so", %{
      conn: conn
    } do
      github([])
      expect(Projects, :create, fn _user, _attrs -> exit(:boom) end)

      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/project")
      render_async(view)

      view |> form("#first-prompt-form", quick_start: [prompt: "Half typed"]) |> render_change()
      assert has_element?(view, "#first-prompt-prompt", "Half typed")

      view |> form("#first-prompt-form", quick_start: [prompt: "Half typed"]) |> render_submit()
      # Await the monitored crash and its LiveView response, including coverage/logging overhead.
      assert render_async(view, 5_000) =~ "The operation could not finish"
      refute has_element?(view, "#first-prompt-submit[disabled]")
      assert has_element?(view, "#first-prompt-prompt", "Half typed")
    end

    test "without an agent it says where to connect one and does not start", %{conn: conn} do
      github([])
      reject(&Projects.create/2)
      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/project")
      render_async(view)
      assert has_element?(view, "#first-prompt-no-agent a[href='/welcome/agent']")
      assert has_element?(view, "#first-prompt-submit[disabled]")
    end

    test "a session that went without notice creates nothing", %{conn: conn} do
      github([%{account: "acme", id: 42}], [%{full_name: "acme/app", installation_id: 42}])
      reject(&Projects.create/2)
      reject(&Tracks.open/3)
      {token, session} = insert_session(connected())
      conn = Plug.Test.init_test_session(conn, session_token: token)
      {:ok, view, _} = live(conn, "/welcome/project")
      render_async(view)

      Repo.delete!(session)
      :sys.replace_state(view.pid, &age_session_guard/1)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#first-prompt-form", quick_start: [prompt: "Run the migration"])
               |> render_submit()

      assert Repo.all(Track) == []
      assert Repo.all(PromptQueue.Item) == []
    end
  end

  describe "leaving" do
    test "skipping is finishing: the workspace does not send them back", %{conn: conn} do
      user = fresh()
      conn = log_in_user(conn, user)
      {:ok, view, _} = live(conn, "/welcome")

      view |> element("#welcome-skip") |> render_click()
      assert_redirect(view, "/home")

      assert {:ok, _view, _html} = live(conn, "/home")
    end

    test "signing out somewhere else takes this page with it", %{conn: conn} do
      {token, _session} = insert_session(fresh())
      conn = Plug.Test.init_test_session(conn, session_token: token)
      {:ok, view, _} = live(conn, "/welcome/agent")

      Accounts.end_session(Crypto.sha256(token))
      assert_redirect(view, "/login", 1_000)
    end

    test "a session that went without notice does not survive moving between steps", %{
      conn: conn
    } do
      {token, session} = insert_session(fresh())
      conn = Plug.Test.init_test_session(conn, session_token: token)
      {:ok, view, _} = live(conn, "/welcome")

      Repo.delete!(session)
      :sys.replace_state(view.pid, &age_session_guard/1)

      # A patch is not a message, so no hook runs for it; the page checks.
      view |> element("#welcome-start") |> render_click()
      assert_redirect(view, "/login")
    end

    test "a session that went without notice cannot connect a credential", %{conn: conn} do
      reject(&Inference.connect/2)
      {token, session} = insert_session(fresh())
      conn = Plug.Test.init_test_session(conn, session_token: token)
      {:ok, view, _} = live(conn, "/welcome/agent")
      view |> element("#agent-claude") |> render_click()

      Repo.delete!(session)

      :sys.replace_state(view.pid, &age_session_guard/1)

      # The panel is a component, so the page's hook never sees the submit;
      # `RavixWeb.Live.Hooks` asks for it and sends the whole page to sign in.
      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> form("#credential-form", credential: [value: "k"]) |> render_submit()
    end
  end
end

defmodule RavixWeb.OnboardingLiveTest do
  use RavixWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Accounts, Crypto, Projects, Repo}
  alias Ravix.Accounts.{Inference, User}
  alias RavixWeb.Live.Guard

  setup :verify_on_exit!

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
        assert {:error, {:live_redirect, %{to: "/welcome"}}} = live(conn, path)
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
    test "says the four things, and that the owner is the one billed", %{conn: conn} do
      {:ok, view, html} = live(log_in_user(conn, fresh()), "/welcome")

      assert html =~ "A project is a repository."
      assert html =~ "Every project has a computer."
      assert html =~ "A project holds many conversations."
      assert html =~ "you are the one billed"

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
      assert html =~ "A project is a repository."
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

    test "connecting sends the value to the context and nowhere else, then moves on", %{
      conn: conn
    } do
      user = fresh()
      github([])

      expect(Inference, :connect, fn caller, attrs ->
        assert caller.id == user.id
        assert attrs == %{agent: :claude, kind: :subscription, value: "sk-ant-oat01-private"}

        Accounts.save_setup(caller, %{
          agent: :claude,
          credential_kind: :subscription,
          credential_set_id: "set-1"
        })
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/welcome/agent")
      view |> element("#agent-claude") |> render_click()

      view
      |> form("#credential-form", credential: [value: "sk-ant-oat01-private"])
      |> render_submit()

      refute render(view) =~ "sk-ant-oat01-private"
      render_async(view)
      assert_patch(view, "/welcome/github")
      refute render(view) =~ "sk-ant-oat01-private"
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
      {:ok, _view, html} = live(log_in_user(conn, connected()), "/welcome/agent")
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

      expect(Inference, :begin_link, fn caller ->
        assert caller.id == user.id
        {:ok, chatgpt_link()}
      end)

      stub(Inference, :poll_link, fn caller, %Inference.Link{attempt_id: "att-1"} ->
        assert caller.id == user.id

        case Agent.get_and_update(polls, &{&1 + 1, &1 + 1}) do
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

      assert html =~ "only type it if you started this sign-in yourself"
      refute has_element?(view, "#chatgpt-connect")

      # The page ticks itself; here the ticks are sent by hand so the test
      # does not wait out the interval.
      send(view.pid, {:agent_panel, "agent-panel", :poll_link})
      html = render_async(view)
      assert html =~ "ABCD-EFGH"

      send(view.pid, {:agent_panel, "agent-panel", :poll_link})
      render_async(view)
      assert_patch(view, "/welcome/github")
      assert %User{agent: :codex, credential_kind: :subscription} = Repo.get!(User, user.id)
    end

    test "a sign-in that ends badly says why, and the button comes back", %{conn: conn} do
      linking()
      expect(Inference, :begin_link, fn _user -> {:ok, chatgpt_link()} end)

      expect(Inference, :poll_link, fn _user, _link ->
        {:error, {:unprocessable, "link_failed", "ChatGPT refused the code."}}
      end)

      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/agent")
      view |> element("#agent-codex") |> render_click()
      view |> element("#kind-subscription") |> render_click()
      view |> element("#chatgpt-connect") |> render_click()
      render_async(view)

      send(view.pid, {:agent_panel, "agent-panel", :poll_link})
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

      {:ok, _view, html} =
        live(log_in_user(conn, connected(agent: :codex)), "/welcome/agent")

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

  describe "the first project" do
    test "is created through the context as this person, finishes the walkthrough, and opens a first track",
         %{conn: conn} do
      user = connected()
      github([%{account: "acme", id: 42}], [%{full_name: "acme/app", installation_id: 42}])

      expect(Projects, :create, fn caller, attrs ->
        assert caller.id == user.id
        assert attrs == %{"name" => "", "repo" => "acme/app", "installation_id" => 42}
        {:ok, %{id: "p-new"}}
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/welcome/project")
      render_async(view)

      view
      |> form("#first-project-form", new_project: [repo: "acme/app", name: ""])
      |> render_submit()

      # The page leaves as soon as the project exists, so there is no view
      # left to `render_async/1`; the redirect is the thing to wait for.
      assert_redirect(view, "/p/p-new?new=track", 1_000)
      assert %User{onboarded_at: %DateTime{}} = Repo.get!(User, user.id)
    end

    test "a repository the list never offered is not sent as one", %{conn: conn} do
      github([%{account: "acme", id: 42}], [%{full_name: "acme/app", installation_id: 42}])

      expect(Projects, :create, fn _user, attrs ->
        assert attrs == %{"name" => "Mine"}
        {:error, {:unavailable, "Provisioning is offline"}}
      end)

      {:ok, view, _} = live(log_in_user(conn, connected()), "/welcome/project")
      render_async(view)

      render_submit(view, "create-project", %{
        "new_project" => %{"name" => "Mine", "repo" => "someone-elses/private"}
      })

      assert render_async(view) =~ "Provisioning is offline"
      # Not finished: they are still here and can try again.
      refute has_element?(view, "#first-project-form button[disabled]")
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

      view |> form("#first-project-form", new_project: [name: "Half typed"]) |> render_change()
      assert has_element?(view, "input[name='new_project[name]'][value='Half typed']")

      view |> form("#first-project-form", new_project: [name: "Half typed"]) |> render_submit()
      assert render_async(view) =~ "The operation could not finish"
      refute has_element?(view, "#first-project-form button[disabled]")
    end

    test "a deployment with no GitHub App says so and still offers a scratch machine", %{
      conn: conn
    } do
      stub(Accounts, :capabilities, fn -> %{github: false} end)
      reject(&Projects.repos/2)

      {:ok, view, html} = live(log_in_user(conn, connected()), "/welcome/github")
      assert html =~ "GitHub is not configured for this deployment"

      view |> element("#github-continue") |> render_click()
      assert_patch(view, "/welcome/project")
      assert has_element?(view, "#first-project-form")
    end

    test "without an agent it says what that means rather than refusing", %{conn: conn} do
      github([])
      {:ok, view, _} = live(log_in_user(conn, fresh()), "/welcome/project")
      assert has_element?(view, "#project-no-agent")
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
      # the panel asks the guard itself and sends the whole page to sign in.
      assert {:error, {:live_redirect, %{to: "/login"}}} =
               view |> form("#credential-form", credential: [value: "k"]) |> render_submit()
    end
  end
end

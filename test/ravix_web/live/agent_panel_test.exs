defmodule RavixWeb.Live.AgentPanelTest do
  @moduledoc """
  The agent panel as the workspace's account dialog: the place somebody
  comes back to after the walkthrough. What the walkthrough proves about the
  panel (`RavixWeb.OnboardingLiveTest`) holds here too, since it is the same
  component; these tests are about what the *workspace* does around it.
  """
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Accounts, Repo}
  alias Ravix.Accounts.{Inference, User}

  setup :verify_on_exit!

  defp open_account(conn, user) do
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    view |> element("#open-account") |> render_click()
    view
  end

  test "opens from the rail, shows what is connected, and says who pays", %{conn: conn} do
    user = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "s")
    stub(Inference, :held, fn _ -> {:ok, [{:claude, :api_key}]} end)
    view = open_account(conn, user)

    assert has_element?(view, "#account-dialog h2", "Your account")
    html = render_async(view)
    assert html =~ "@#{user.login}"
    assert html =~ "whoever is working"
    assert has_element?(view, "#agent-claude[aria-pressed=true]")
    assert has_element?(view, "#kind-api_key[aria-pressed=true]")
    assert html =~ "Claude Code is connected with your API key"
    assert has_element?(view, "a[href='/api/auth/install']")
  end

  test "a ChatGPT subscription is shown as Fountain reports it", %{conn: conn} do
    user = insert_user(agent: :codex, credential_kind: :subscription, credential_set_id: "s")
    stub(Inference, :link_status, fn _ -> {:ok, %{enabled?: true, pending: nil}} end)

    expect(Inference, :subscription, fn caller ->
      assert caller.id == user.id

      {:ok,
       %{
         id: "g-1",
         status: "active",
         plan_type: "plus",
         account_email: "me@example.com",
         exhausted_until: "2026-09-22T09:00:00Z"
       }}
    end)

    view = open_account(conn, user)
    html = render_async(view)
    assert has_element?(view, "#chatgpt-subscription .chip.warn", "Usage spent")
    assert html =~ "ChatGPT Plus, me@example.com."
    assert html =~ "spent until 2026-09-22T09:00:00Z"

    # Choosing the other agent and back re-reads nothing; the row is about
    # the person, not the choice. A reconnect would.
    reject(&Inference.subscription/1)
    view |> element("#agent-claude") |> render_click()
    view |> element("#agent-codex") |> render_click()
    assert render(view) =~ "Usage spent"
  end

  test "connecting through the dialog changes the person on the page and says so", %{conn: conn} do
    user = insert_user()

    stub(Inference, :held, fn user ->
      {:ok, if(user.agent, do: [{:claude, :subscription}], else: [])}
    end)

    expect(Inference, :connect, fn caller,
                                   %{agent: :claude, kind: :subscription, value: "sk-ant-oat01-x"} ->
      Accounts.save_setup(caller, %{
        agent: :claude,
        credential_kind: :subscription,
        credential_set_id: "s"
      })
    end)

    view = open_account(conn, user)
    view |> element("#agent-claude") |> render_click()
    view |> form("#credential-form", credential: [value: "sk-ant-oat01-x"]) |> render_submit()

    # Connecting starts a fresh held-credential read after the write finishes.
    render_async(view)
    html = render_async(view)
    assert html =~ "Claude Code is connected. New projects default to Claude Code."
    assert html =~ "Claude Code is connected with your subscription"
    refute html =~ "sk-ant-oat01-x"
    assert %User{agent: :claude} = Repo.get!(User, user.id)
  end

  test "the new-project form connects inline without leaving the draft", %{conn: conn} do
    stub(Inference, :usable_agents, fn _ -> {:ok, []} end)
    {:ok, view, _} = live(log_in_user(conn, insert_user()), "/home")
    render_click(view, "dialog", %{name: "new-project"})
    render_async(view)
    view |> element("#project-agent-claude") |> render_click()
    assert has_element?(view, "#new-project-dialog #credential-form")
    refute has_element?(view, "#account-dialog")
  end

  test "the workspace hands the panel its polling tick", %{conn: conn} do
    user = insert_user()
    stub(Inference, :link_status, fn _ -> {:ok, %{enabled?: true, pending: nil}} end)

    expect(Inference, :begin_link, fn _ ->
      {:ok,
       %Inference.Link{
         attempt_id: "att-1",
         set_id: "s",
         user_code: "WXYZ-1234",
         verification_url: "https://auth.openai.com/codex/device",
         trusted?: true,
         poll_interval: 1
       }}
    end)

    expect(Inference, :poll_link, fn _, %Inference.Link{attempt_id: "att-1"} ->
      {:ok, :pending}
    end)

    view = open_account(conn, user)
    view |> element("#agent-codex") |> render_click()
    view |> element("#kind-subscription") |> render_click()
    view |> element("#chatgpt-connect") |> render_click()
    assert render_async(view) =~ "WXYZ-1234"

    send(view.pid, {:agent_panel, "agent-panel", :poll_link})
    # The tick reaches the panel through `send_update/2`, one message
    # later, so the poll it starts is not outstanding when `render_async/1`
    # asks straight away; rendering once lets the page take the tick first.
    render(view)
    assert render_async(view) =~ "WXYZ-1234"
  end

  test "what the set holds is read from Fountain, and each thing has its own Remove", %{
    conn: conn
  } do
    user = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "s")

    # What Fountain says the set holds follows the row, as it does when every
    # write went through the context: two things before, one after.
    stub(Inference, :held, fn
      %User{credential_kind: :api_key} -> {:ok, [{:claude, :api_key}, {:codex, :api_key}]}
      %User{credential_kind: nil} -> {:ok, [{:codex, :api_key}]}
    end)

    expect(Inference, :disconnect, fn caller, :claude, :api_key ->
      assert caller.id == user.id
      Accounts.save_setup(caller, %{credential_kind: nil})
    end)

    view = open_account(conn, user)
    render_async(view)
    assert has_element?(view, "#held-claude-api_key .chip.ok", "Default for new projects")
    assert has_element?(view, "#held-codex-api_key")
    refute has_element?(view, "#held-codex-api_key .chip")

    assert has_element?(
             view,
             "#remove-claude-api_key[data-confirm*='Projects using Claude Code']"
           )

    assert has_element?(view, "#remove-codex-api_key[data-confirm]")
    refute has_element?(view, "#remove-codex-api_key[data-confirm*='nothing to run on']")
    assert render(view) =~ "ends your open tracks"

    view |> element("#remove-claude-api_key") |> render_click()
    render_async(view)
    # The component sends the parent its flash after its async result. Drain
    # that queued message before checking the parent's rendered notice.
    html = render(view)

    assert html =~
             "Removed."

    refute has_element?(view, "#held-claude-api_key")
    assert has_element?(view, "#held-codex-api_key")
    refute has_element?(view, "#welcome-connected")
    # The choice stays where it was, so what to connect instead is one paste away.
    assert has_element?(view, "#agent-claude[aria-pressed=true]")
    assert has_element?(view, "#kind-api_key[aria-pressed=true]")
    assert has_element?(view, "#credential-form")

    assert %User{agent: :claude, credential_kind: nil, credential_set_id: "s"} =
             Repo.get!(User, user.id)
  end

  test "removing something not in use says only that it is gone", %{conn: conn} do
    user = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s")
    stub(Inference, :held, fn _ -> {:ok, [{:claude, :subscription}, {:codex, :api_key}]} end)
    expect(Inference, :disconnect, fn caller, :codex, :api_key -> {:ok, caller} end)

    view = open_account(conn, user)
    render_async(view)
    view |> element("#remove-codex-api_key") |> render_click()
    render_async(view)
    assert has_element?(view, "#flash-info", "Removed.")
    refute has_element?(view, "#flash-info", "nothing to run on")
    assert has_element?(view, "#welcome-connected")
  end

  test "a slot emptied outside this page is said, rather than drawn as connected", %{conn: conn} do
    user = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s")
    stub(Inference, :held, fn _ -> {:ok, []} end)

    view = open_account(conn, user)
    html = render_async(view)
    assert has_element?(view, "#held-missing")
    assert html =~ "Nothing is stored for Claude Code any more"
    assert html =~ "removed outside this page"
    refute has_element?(view, ".agent-held-list")
  end

  test "a set Fountain would not list is not drawn as empty", %{conn: conn} do
    user = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s")

    stub(Inference, :held, fn _ ->
      {:error, %Ravix.Fountain.Error{status: 503, message: "down"}}
    end)

    view = open_account(conn, user)
    render_async(view)
    refute has_element?(view, "#agent-held")
    refute has_element?(view, "#held-missing")
    refute has_element?(view, "#welcome-connected")
    assert has_element?(view, "#agent-claude-status", "Connection status unavailable")
  end

  test "a session that went without notice cannot remove through the dialog", %{conn: conn} do
    reject(&Inference.disconnect/3)
    user = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "s")
    stub(Inference, :held, fn _ -> {:ok, [{:claude, :api_key}]} end)
    {token, session} = insert_session(user)
    conn = Plug.Test.init_test_session(conn, session_token: token)
    {:ok, view, _} = live(conn, "/home")
    view |> element("#open-account") |> render_click()
    render_async(view)
    assert has_element?(view, "#remove-claude-api_key")

    Repo.delete!(session)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> element("#remove-claude-api_key") |> render_click()
  end

  test "a session that went without notice cannot connect through the dialog", %{conn: conn} do
    reject(&Inference.connect/2)
    {token, session} = insert_session(insert_user())
    conn = Plug.Test.init_test_session(conn, session_token: token)
    {:ok, view, _} = live(conn, "/home")
    view |> element("#open-account") |> render_click()
    view |> element("#agent-claude") |> render_click()

    Repo.delete!(session)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> form("#credential-form", credential: [value: "k"]) |> render_submit()
  end

  for path <- ["/home", "/welcome/agent"] do
    @path path
    test "#{path} shows both connected agents and changes the default explicitly", %{conn: conn} do
      user = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "s")
      project = insert_project(user: user, runtime: "claude")
      stub(Inference, :held, fn _ -> {:ok, [{:claude, :api_key}, {:codex, :api_key}]} end)

      expect(Inference, :make_default, fn caller, :codex ->
        assert caller.id == user.id
        Accounts.save_setup(caller, %{agent: :codex, credential_kind: :api_key})
      end)

      reject(&Ravix.Fountain.update_agent/3)
      {:ok, view, _} = live(log_in_user(conn, user), @path)
      if @path == "/home", do: view |> element("#open-account") |> render_click()
      render_async(view)
      assert has_element?(view, "#agent-claude-status", "Connected")
      assert has_element?(view, "#agent-codex-status", "Connected")
      assert has_element?(view, "#agent-claude-status", "Default for new projects")
      view |> element("#make-default-codex") |> render_click()
      render_async(view)
      assert has_element?(view, "#agent-codex-status", "Default for new projects")
      assert has_element?(view, "#make-default-claude")
      assert Repo.get!(User, user.id).agent == :codex
      assert Repo.get!(Ravix.Projects.Project, project.id).runtime == "claude"
    end

    test "#{path} rejects Make default after session revocation", %{conn: conn} do
      user = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "s")
      stub(Inference, :held, fn _ -> {:ok, [{:codex, :api_key}]} end)
      reject(&Inference.make_default/2)
      {token, session} = insert_session(user)
      {:ok, view, _} = live(Plug.Test.init_test_session(conn, session_token: token), @path)
      if @path == "/home", do: view |> element("#open-account") |> render_click()
      render_async(view)
      Repo.delete!(session)
      view |> element("#make-default-codex") |> render_click()
      assert_redirect(view, "/login")
      assert Repo.get!(User, user.id).agent == :claude
    end
  end

  test "connecting a second agent reports that agent and does not announce a new default", %{
    conn: conn
  } do
    user = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "s")
    stub(Inference, :held, fn _ -> {:ok, [{:claude, :api_key}, {:codex, :api_key}]} end)

    expect(Inference, :connect, fn caller, %{agent: :codex, kind: :api_key, value: "mock-key"} ->
      {:ok, caller}
    end)

    view = open_account(conn, user)
    render_async(view)
    view |> element("#agent-codex") |> render_click()
    view |> form("#credential-form", credential: [value: "mock-key"]) |> render_submit()
    render_async(view)
    assert has_element?(view, "#flash-info", "Codex is connected.")
    refute has_element?(view, "#flash-info", "New projects")
    assert has_element?(view, "#agent-codex[aria-pressed=true]")
    assert has_element?(view, "#agent-claude-status", "Default for new projects")
  end

  test "disconnect notices name only owned projects using the removed agent", %{conn: conn} do
    user = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "s")
    insert_project(user: user, name: "Claude project", runtime: "claude")
    insert_project(user: user, name: "Codex project", runtime: "codex")
    insert_project(name: "Someone else's Claude", runtime: "claude")

    stub(Inference, :held, fn user ->
      {:ok,
       if(user.credential_kind,
         do: [{:claude, :api_key}, {:codex, :api_key}],
         else: [{:codex, :api_key}]
       )}
    end)

    expect(Inference, :disconnect, fn caller, :claude, :api_key ->
      Accounts.save_setup(caller, %{credential_kind: nil})
    end)

    expect(Inference, :usable?, fn _, :claude, [fresh: true] -> {:ok, false} end)
    view = open_account(conn, user)
    render_async(view)
    view |> element("#remove-claude-api_key") |> render_click()
    render_async(view)
    render_async(view)
    assert has_element?(view, "#flash-info", "Connect Claude Code again to run: Claude project")
    refute has_element?(view, "#flash-info", "Codex project")
    refute has_element?(view, "#flash-info", "Someone else's")
  end
end

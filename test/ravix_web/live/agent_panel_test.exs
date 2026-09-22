defmodule RavixWeb.Live.AgentPanelTest do
  @moduledoc """
  The agent panel as the workspace's account dialog: the place somebody
  comes back to after the walkthrough. What the walkthrough proves about the
  panel (`RavixWeb.OnboardingLiveTest`) holds here too, since it is the same
  component; these tests are about what the *workspace* does around it.
  """
  use RavixWeb.ConnCase, async: false
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
    view = open_account(conn, user)

    assert has_element?(view, "#account-dialog h2", "Your account")
    html = render(view)
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

    html = render_async(view)
    assert html =~ "Claude Code is connected. New projects are built with it."
    assert html =~ "Claude Code is connected with your subscription"
    refute html =~ "sk-ant-oat01-x"
    assert %User{agent: :claude} = Repo.get!(User, user.id)
  end

  test "the new-project form's nudge opens the account dialog rather than leaving the workspace",
       %{conn: conn} do
    {:ok, view, _} = live(log_in_user(conn, insert_user()), "/home")
    view |> element(".home-action", "Quick start") |> render_click()
    assert has_element?(view, "#new-project-no-agent button", "Connect Claude Code or Codex")

    view |> element("#new-project-no-agent button") |> render_click()
    assert has_element?(view, "#account-dialog")
    refute has_element?(view, "#new-project-dialog")
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
    assert has_element?(view, "#held-claude-api_key .chip.ok", "In use")
    assert has_element?(view, "#held-codex-api_key")
    refute has_element?(view, "#held-codex-api_key .chip")
    assert has_element?(view, "#remove-claude-api_key[data-confirm*='nothing to run on']")
    assert has_element?(view, "#remove-codex-api_key[data-confirm]")
    refute has_element?(view, "#remove-codex-api_key[data-confirm*='nothing to run on']")
    assert render(view) =~ "ends your open tracks"

    view |> element("#remove-claude-api_key") |> render_click()
    html = render_async(view)

    assert html =~
             "Removed. Projects you own have nothing to run on until you connect Claude Code again."

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
    assert has_element?(view, "#welcome-connected")
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

    assert {:error, {:live_redirect, %{to: "/login"}}} =
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

    assert {:error, {:live_redirect, %{to: "/login"}}} =
             view |> form("#credential-form", credential: [value: "k"]) |> render_submit()
  end
end

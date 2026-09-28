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
  alias Ravix.Fountain.FakeTransport

  setup :verify_on_exit!

  defp open_account(conn, user) do
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    view |> element("#open-account") |> render_click()
    view
  end

  test "the thread default round trips and offers only connected runtimes", %{conn: conn} do
    user = insert_user()

    catalog = %Ravix.Fountain.Shapes.Catalog{
      runtimes: ["claude", "codex"],
      models: %{
        "claude" => ["anthropic/claude-sonnet-5", "anthropic/claude-opus-5-5"],
        "codex" => ["openai/gpt-6-astra"]
      }
    }

    stub(Ravix.Fountain, :client, fn -> FakeTransport.client([], verify: false) end)

    stub(Ravix.MachineCache, :catalog, fn _ -> {:ok, catalog} end)
    stub(Inference, :held, fn _ -> {:ok, [{:claude, :api_key}]} end)
    stub(Inference, :usable?, fn _, runtime, _ -> {:ok, runtime == "claude"} end)
    view = open_account(conn, user)
    render_async(view)
    render_async(view)

    assert has_element?(
             view,
             "#thread-default-choice option[value='claude|anthropic/claude-opus-5-5']"
           )

    refute has_element?(view, "#thread-default-choice option[value='codex|openai/gpt-6-astra']")

    view
    |> form("#thread-default-form", preference: %{choice: "claude|anthropic/claude-opus-5-5"})
    |> render_submit()

    render_async(view)
    assert Repo.get!(User, user.id).preferred_model == "anthropic/claude-opus-5-5"
    assert has_element?(view, "#thread-default-form [role=status]", "Thread default saved.")

    view
    |> form("#thread-default-form", preference: %{choice: "claude|anthropic/claude-sonnet-5"})
    |> render_change()

    refute has_element?(view, "#thread-default-form [role=status]")
    stub(Inference, :usable?, fn _, _, _ -> {:ok, false} end)

    view
    |> form("#thread-default-form", preference: %{choice: "claude|anthropic/claude-sonnet-5"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#thread-default-form [role=alert]", "Connect this agent first.")
    refute has_element?(view, "#thread-default-form [role=status]")

    view = open_account(conn, user)
    render_async(view)
    render_async(view)

    assert has_element?(
             view,
             "#thread-default-choice option[value='claude|anthropic/claude-opus-5-5'][selected]"
           )
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

  for {first, second, label} <- [{:claude, :codex, "Codex"}, {:codex, :claude, "Claude Code"}] do
    test "#{first}-only account offers #{second}, and the card disappears after connecting", %{
      conn: conn
    } do
      first = unquote(first)
      second = unquote(second)
      user = insert_user(agent: first, credential_kind: :api_key, credential_set_id: "s")
      stub(Inference, :subscription, fn _ -> {:ok, nil} end)
      stub(Inference, :link_status, fn _ -> {:ok, %{enabled?: true, pending: nil}} end)
      expect(Inference, :held, fn _ -> {:ok, [{first, :api_key}]} end)
      view = open_account(conn, user)
      render_async(view)
      assert has_element?(view, "#second-agent-nudge", "Also connect " <> unquote(label))
      view |> element("#connect-second-agent") |> render_click()
      assert has_element?(view, "#agent-#{second}[aria-pressed=true]")
      expect(Inference, :connect, fn _, %{agent: ^second} -> {:ok, user} end)
      expect(Inference, :held, fn _ -> {:ok, [{first, :api_key}, {second, :api_key}]} end)
      view |> form("#credential-form", credential: [value: "test-key"]) |> render_submit()
      render_async(view)
      render_async(view)
      refute has_element?(view, "#second-agent-nudge")
    end
  end

  test "each agent describes its held credentials despite stale single-agent metadata", %{
    conn: conn
  } do
    user = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s")

    stub(Inference, :held, fn _ ->
      {:ok, [{:claude, :api_key}, {:codex, :subscription}, {:codex, :api_key}]}
    end)

    view = open_account(conn, user)
    render_async(view)
    assert has_element?(view, "#agent-claude small", "Connected with your API key.")

    assert has_element?(
             view,
             "#agent-codex small",
             "Connected with your ChatGPT subscription and API key."
           )

    refute has_element?(view, "#agent-claude small", "your subscription")
    assert has_element?(view, "#held-claude-api_key", "API key")
  end

  for {raw, label} <- [
        {"2026-09-22T09:00:00Z", "Sep 22 at 09:00 UTC"},
        {"unknown reset", "unknown reset"},
        {"2026-09-22T11:00:00+02:00", "Sep 22 at 09:00 UTC"}
      ] do
    test "a ChatGPT subscription reset shows #{raw}", %{conn: conn} do
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
           exhausted_until: unquote(raw)
         }}
      end)

      view = open_account(conn, user)
      html = render_async(view)
      assert has_element?(view, "#chatgpt-subscription .chip.warn", "Usage spent")
      assert html =~ "ChatGPT Plus, me@example.com."

      assert has_element?(
               view,
               ~s(#chatgpt-subscription time[datetime="#{unquote(raw)}"]),
               unquote(label)
             )

      # Choosing the other agent and back re-reads nothing; the row is about
      # the person, not the choice. A reconnect would.
      reject(&Inference.subscription/1)
      view |> element("#agent-claude") |> render_click()
      refute has_element?(view, "#chatgpt-subscription")
      view |> element("#agent-codex") |> render_click()
      assert render(view) =~ "Usage spent"
    end
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

    refute has_element?(view, "#agent-panel [data-confirm]")
    assert has_element?(view, "#remove-codex-api_key")

    view |> element("#remove-claude-api_key") |> render_click()
    view |> element("#confirm-agent-disconnect") |> render_click()
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
    view |> element("#confirm-agent-disconnect") |> render_click()
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
    assert has_element?(view, "#agent-disconnect-confirmation", "Claude project")
    refute has_element?(view, "#agent-disconnect-confirmation", "Codex project")
    refute has_element?(view, "#agent-disconnect-confirmation", "Someone else's")
    view |> element("#confirm-agent-disconnect") |> render_click()
    render_async(view)
    render_async(view)
    assert has_element?(view, "#flash-info", "Connect Claude Code again to run: Claude project")
    refute has_element?(view, "#flash-info", "Codex project")
    refute has_element?(view, "#flash-info", "Someone else's")
  end

  test "removal needs an in-app decision and cancellation preserves the credential", %{conn: conn} do
    user = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "s")

    for name <- ["ravix2", "second", "third"],
        do: insert_project(user: user, name: name, runtime: "codex")

    stub(Inference, :held, fn _ -> {:ok, [{:codex, :api_key}]} end)
    reject(&Inference.disconnect/3)
    view = open_account(conn, user)
    render_async(view)
    view |> element("#remove-codex-api_key") |> render_click()

    assert has_element?(
             view,
             "#agent-disconnect-confirmation",
             "ravix2 and 2 other projects use Codex"
           )

    refute has_element?(view, "#agent-panel [data-confirm]")
    view |> element("[phx-click=cancel-disconnect]") |> render_click()
    refute has_element?(view, "#agent-disconnect-confirmation")
    assert has_element?(view, "#held-codex-api_key")
  end

  test "revocation after the removal warning prevents confirming it", %{conn: conn} do
    user = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "s")
    stub(Inference, :held, fn _ -> {:ok, [{:codex, :api_key}]} end)
    reject(&Inference.disconnect/3)
    conn = log_in_user(conn, user)
    view = open_account(conn, user)
    render_async(view)
    view |> element("#remove-codex-api_key") |> render_click()
    # Revoke this view's session, without depending on notification delivery.
    Repo.delete_all(Ravix.Accounts.Session)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> element("#confirm-agent-disconnect") |> render_click()
  end

  # ── a ChatGPT account already linked here ─────────────────────────────

  defp link(attempt_id) do
    %Inference.Link{
      attempt_id: attempt_id,
      set_id: "s",
      user_code: "WXYZ-1234",
      verification_url: "https://auth.openai.com/codex/device",
      trusted?: true,
      poll_interval: 60
    }
  end

  # Up to the refused poll: the panel is showing a code and has just been told
  # why the sign-in could not finish.
  defp refuse_with(conn, user, conflict) do
    stub(Inference, :link_status, fn _ -> {:ok, %{enabled?: true, pending: nil}} end)
    expect(Inference, :begin_link, fn _ -> {:ok, link("att-1")} end)
    expect(Inference, :poll_link, fn _, _ -> {:error, {:link_conflict, conflict}} end)

    view = open_account(conn, user)
    view |> element("#agent-codex") |> render_click()
    view |> element("#kind-subscription") |> render_click()
    view |> element("#chatgpt-connect") |> render_click()
    render_async(view)
    send(view.pid, {:agent_panel, "agent-panel", :poll_link})
    render(view)
    render_async(view)
    view
  end

  for {resolution, label, words} <- [
        {:reconnect, "Reconnect it", "under your own earlier sign-in"},
        {:remove, "Remove the old connection and try again", "nothing is using"}
      ] do
    test "a #{resolution} conflict says why and offers one button", %{conn: conn} do
      user = insert_user()
      resolution = unquote(resolution)

      conflict = %Inference.Conflict{
        resolution: resolution,
        grant_id: "g-1",
        message: "That ChatGPT account is already connected here, #{unquote(words)}."
      }

      view = refuse_with(conn, user, conflict)

      assert has_element?(view, "#link-error", unquote(words))
      assert has_element?(view, "#chatgpt-resolve-conflict", unquote(label))
      refute has_element?(view, "#chatgpt-code")

      # The button hands the context the conflict the *panel* is holding: a
      # grant id from a browser is a grant id anybody could name.
      expect(Inference, :resolve_conflict, fn caller, held ->
        assert caller.id == user.id
        assert held == conflict
        {:ok, link("att-2")}
      end)

      view |> element("#chatgpt-resolve-conflict") |> render_click()
      html = render_async(view)
      assert html =~ "WXYZ-1234"
      refute has_element?(view, "#chatgpt-conflict")
      refute has_element?(view, "#link-error")
    end
  end

  test "a second press while the first is still asking starts nothing", %{conn: conn} do
    user = insert_user()
    parent = self()

    conflict = %Inference.Conflict{
      resolution: :reconnect,
      grant_id: "g-1",
      message: "Reconnect it rather than connecting it twice."
    }

    # Once, however many times the button is pressed: the repair is a write on
    # Fountain and two of them is one too many.
    expect(Inference, :resolve_conflict, 1, fn _, _ ->
      send(parent, {:resolving, self()})

      receive do
        :finish -> {:ok, link("att-2")}
      end
    end)

    view = refuse_with(conn, user, conflict)
    view |> element("#chatgpt-resolve-conflict") |> render_click()
    assert_receive {:resolving, task}

    # Sent past the disabled button, because a disabled button is a browser's
    # courtesy and the guard has to be the server's.
    render_click(with_target(view, "#agent-panel"), "resolve-conflict", %{})
    send(task, :finish)
    assert render_async(view) =~ "WXYZ-1234"
  end

  test "another Ravix login's subscription is said, with no name and no button", %{conn: conn} do
    user = insert_user()
    other = insert_user()
    reject(&Inference.resolve_conflict/2)

    conflict = %Inference.Conflict{
      resolution: :elsewhere,
      message:
        "This ChatGPT account is already connected to a different Ravix login. " <>
          "Disconnect it from that login, or ask whoever runs this Ravix to move it."
    }

    view = refuse_with(conn, user, conflict)

    assert has_element?(view, "#link-error", "already connected to a different Ravix login")
    refute has_element?(view, "#chatgpt-conflict")
    refute render(view) =~ other.id
    refute render(view) =~ "ravix:"

    # A button that is not drawn is still a message somebody can send, so the
    # refusal is the panel's own: there is nothing here for it to act on.
    render_click(with_target(view, "#agent-panel"), "resolve-conflict", %{})
    refute has_element?(view, "#chatgpt-code")
    assert has_element?(view, "#link-error", "already connected to a different Ravix login")
  end

  test "starting over after a conflict clears the refusal and its button", %{conn: conn} do
    user = insert_user()

    conflict = %Inference.Conflict{
      resolution: :reconnect,
      grant_id: "g-1",
      message: "Reconnect it rather than connecting it twice."
    }

    view = refuse_with(conn, user, conflict)
    assert has_element?(view, "#chatgpt-resolve-conflict")

    expect(Inference, :begin_link, fn _ -> {:ok, link("att-3")} end)
    view |> element("#chatgpt-connect") |> render_click()
    render_async(view)
    refute has_element?(view, "#chatgpt-conflict")
    refute has_element?(view, "#link-error")
    assert has_element?(view, "#chatgpt-code")
  end

  test "an ordinary refusal leaves no button behind", %{conn: conn} do
    user = insert_user()
    reject(&Inference.resolve_conflict/2)

    view =
      refuse_with(conn, user, %Inference.Conflict{
        resolution: :reconnect,
        grant_id: "g-1",
        message: "own"
      })

    assert has_element?(view, "#chatgpt-resolve-conflict")

    expect(Inference, :begin_link, fn _ -> {:ok, link("att-4")} end)

    expect(Inference, :poll_link, fn _, _ ->
      {:error, {:unprocessable, "link_failed", "ChatGPT refused the code."}}
    end)

    view |> element("#chatgpt-connect") |> render_click()
    render_async(view)
    send(view.pid, {:agent_panel, "agent-panel", :poll_link})
    render(view)
    render_async(view)
    assert has_element?(view, "#link-error", "ChatGPT refused the code")
    refute has_element?(view, "#chatgpt-conflict")
  end
end

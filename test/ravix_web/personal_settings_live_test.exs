defmodule RavixWeb.PersonalSettingsLiveTest do
  @moduledoc """
  The signed-in person's settings pages (RAV-77): Profile, Agents,
  Notifications, Appearance and Connected apps, each a section of the
  settings frame, and the You menu linking to each. Connected apps' own
  content is `RavixWeb.ConnectionsLiveTest`'s; the agent panel's is
  `RavixWeb.Live.AgentPanelTest`'s and the walkthrough's.
  """
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Accounts, Repo}
  alias Ravix.Accounts.{Inference, User}
  alias Ravix.Fountain.FakeTransport
  alias RavixWeb.Live.Settings

  setup :verify_on_exit!

  @sections [
    {"profile", "Profile"},
    {"agents", "Agents"},
    {"notifications", "Notifications"},
    {"appearance", "Appearance"},
    {"connected-apps", "Connected apps"}
  ]

  test "the personal sections, in order, open on Profile" do
    assert Settings.sections(:personal) == @sections
    assert Settings.first(:personal) == "profile"

    assert Enum.map(Settings.you_group().items, & &1.path) ==
             Enum.map(@sections, &"/settings/#{elem(&1, 0)}")
  end

  test "the bare address lands on Profile, and an unknown section on Profile too", %{conn: conn} do
    conn = log_in_user(conn, insert_user())
    assert redirected_to(get(conn, "/settings")) == "/settings/profile"

    assert {:error,
            {:live_redirect,
             %{to: "/settings/profile", flash: %{"info" => "Settings page not found."}}}} =
             live(conn, "/settings/nope")
  end

  test "every section is a page on the frame, named in the nav, crumbs and title", %{conn: conn} do
    {:ok, view, _} = live(log_in_user(conn, insert_user()), "/settings/profile")

    for {key, label} <- @sections do
      render_patch(view, "/settings/#{key}")
      assert page_title(view) == "#{label} · You · Ravix"
      assert has_element?(view, ".settings-crumbs [aria-current=page]", label)
      assert has_element?(view, "#settings-title", label)
      assert has_element?(view, "#settings-nav-#{key}[aria-current=page]")
      # The settings frame sits inside the app's shell, top bar and all.
      assert has_element?(view, "#topbar #account-trigger")

      for {other, _} <- @sections,
          other != key,
          do: refute(has_element?(view, "#settings-nav-#{other}[aria-current=page]"))
    end
  end

  test "the You menu is quick toggles and a short list, with Settings opening Profile",
       %{conn: conn} do
    {:ok, view, _} = live(log_in_user(conn, insert_user()), "/home")
    menu = "#topbar #account-menu[popover]"

    # Theme and notifications stay as quick toggles, the same switches the
    # Appearance and Notifications pages draw.
    assert has_element?(view, "#{menu} #theme-picker[phx-hook=Theme]")
    assert has_element?(view, "#{menu} #notify[phx-hook=Notify] [data-notify-toggle]")

    items =
      view
      |> element(menu)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".account-item")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert items == ["Settings", "Help", "What's new", "Sign out"]

    settings =
      "#{menu} button#open-personal-settings[popovertarget='account-menu'][popovertargetaction='hide'][data-leaves-page]"

    view |> element(settings) |> render_click()
    assert_patch(view, "/settings/profile")

    # Every section is a link in the frame's nav from there.
    for {key, _label} <- @sections,
        do: assert(has_element?(view, "#settings-nav-#{key}[href='/settings/#{key}']"))
  end

  test "Profile says who is signed in and where that comes from", %{conn: conn} do
    user =
      insert_user(
        login: "dana",
        name: "Dana Scully",
        avatar_url: "https://avatars.example.test/dana.png"
      )

    {:ok, view, _} = live(log_in_user(conn, user), "/settings/profile")
    assert has_element?(view, "#profile-name", "Dana Scully")
    assert has_element?(view, "#profile-login", "@dana")
    assert has_element?(view, "img.profile-avatar[src='https://avatars.example.test/dana.png']")
    assert has_element?(view, "a[href='https://github.com/settings/profile'][target=_blank]")
    assert has_element?(view, "#profile-repository-access[href='/api/auth/install']")
    assert has_element?(view, "#profile-sign-out[href='/auth/signout'][data-method=post]")
    assert has_element?(view, "#profile-sign-out-everywhere[data-confirm]", "Sign out everywhere")
    # Nothing on it is editable here, so there is nothing to save.
    refute has_element?(view, "#settings-profile form, [phx-hook=UnsavedChanges]")
  end

  test "Profile without a name or picture falls back to the login", %{conn: conn} do
    user = insert_user(login: "anon", name: nil, avatar_url: nil)
    {:ok, view, _} = live(log_in_user(conn, user), "/settings/profile")
    assert has_element?(view, "#profile-name", "anon")
    assert has_element?(view, "span.profile-avatar[aria-hidden=true]")
    refute has_element?(view, "img.profile-avatar")
  end

  describe "Sign out everywhere" do
    test "ends every session of the person, and nobody else's", %{conn: conn} do
      me = insert_user()
      someone = insert_user()
      {token, here} = insert_session(me)
      {_token, elsewhere} = insert_session(me)
      {_token, theirs} = insert_session(someone)

      Accounts.subscribe_session(elsewhere.token_hash)
      Accounts.subscribe_session(theirs.token_hash)

      {:ok, view, _} =
        live(Plug.Test.init_test_session(conn, session_token: token), "/settings/profile")

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> element("#profile-sign-out-everywhere") |> render_click()

      for session <- [here, elsewhere],
          do: refute(Repo.get(Ravix.Accounts.Session, session.token_hash))

      assert Repo.get(Ravix.Accounts.Session, theirs.token_hash)
      # A page open in the other browser is told at once.
      {elsewhere_hash, theirs_hash} = {elsewhere.token_hash, theirs.token_hash}
      assert_received {:session_ended, ^elsewhere_hash}
      refute_received {:session_ended, ^theirs_hash}
    end

    test "names nobody: an id the browser adds is ignored", %{conn: conn} do
      me = insert_user()
      someone = insert_user()
      {_token, theirs} = insert_session(someone)
      {:ok, view, _} = live(log_in_user(conn, me), "/settings/profile")

      view
      |> element("#profile-sign-out-everywhere")
      |> render_click(%{"user" => someone.id, "user_id" => someone.id})

      assert Repo.get(Ravix.Accounts.Session, theirs.token_hash)
    end

    test "a revoked session cannot use it", %{conn: conn} do
      me = insert_user()
      {token, session} = insert_session(me)
      {_token, other} = insert_session(me)

      {:ok, view, _} =
        live(Plug.Test.init_test_session(conn, session_token: token), "/settings/profile")

      Repo.delete!(session)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> element("#profile-sign-out-everywhere") |> render_click()

      # Refused before it ran: the person's other browser is still signed in.
      assert Repo.get(Ravix.Accounts.Session, other.token_hash)
    end
  end

  test "Notifications and Appearance are this browser's switches, drawn for their hooks",
       %{conn: conn} do
    {:ok, view, _} = live(log_in_user(conn, insert_user()), "/settings/notifications")

    assert has_element?(
             view,
             "#notify-setting[phx-hook=NotifyToggle] button[data-notify-toggle][aria-pressed=false]",
             "Desktop notifications"
           )

    # The menu's quick toggle is still there, and still hears the news.
    assert has_element?(view, "#account-menu #notify[phx-hook=Notify]")

    # What reaches the Inbox is said, as the Inbox decides it.
    assert has_element?(view, "#settings-inbox h2", "What reaches your Inbox")
    assert has_element?(view, "#settings-inbox a[href='/inbox']")

    for rule <- ["replied", "failed", "mentions you", "reconnect your agent"],
        do: assert(has_element?(view, "#settings-inbox .inbox-rules li", rule))

    render_patch(view, "/settings/appearance")
    assert has_element?(view, "#appearance-theme[phx-hook=Theme] [data-theme-toggle]")
    assert has_element?(view, "#appearance-theme [data-theme-choice='daylight']")
    refute has_element?(view, "#notify-setting")
  end

  describe "Agents" do
    test "is the compact agent panel, and connecting changes the person on the page", %{
      conn: conn
    } do
      user = insert_user()

      stub(Inference, :held, fn user ->
        {:ok, if(user.agent, do: [{:claude, :subscription}], else: [])}
      end)

      expect(Inference, :connect, fn caller,
                                     %{
                                       agent: :claude,
                                       kind: :subscription,
                                       value: "sk-ant-oat01-x"
                                     } ->
        assert caller.id == user.id

        Accounts.save_setup(caller, %{
          agent: :claude,
          credential_kind: :subscription,
          credential_set_id: "s"
        })
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/settings/agents")
      render_async(view)
      assert has_element?(view, "#settings-agents #settings-agent-panel.agent-panel.compact")
      assert has_element?(view, "#agent-card-claude button#agent-claude", "Connect")
      assert has_element?(view, "#agent-card-codex button#agent-codex", "Connect")
      refute has_element?(view, "#account-dialog")

      view |> element("#agent-claude") |> render_click()
      view |> form("#credential-form", credential: [value: "sk-ant-oat01-x"]) |> render_submit()
      render_async(view)
      html = render_async(view)
      assert html =~ "Claude Code is connected."
      refute html =~ "sk-ant-oat01-x"
      assert has_element?(view, "#agent-card-claude.connected", "Default for new projects")
      assert %User{agent: :claude} = Repo.get!(User, user.id)
    end

    test "works as in the walkthrough: a card makes itself the default, its menu removes",
         %{conn: conn} do
      user = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "s")
      stub(Inference, :held, fn _ -> {:ok, [{:claude, :api_key}, {:codex, :api_key}]} end)

      expect(Inference, :make_default, fn caller, :codex ->
        assert caller.id == user.id
        Accounts.save_setup(caller, %{agent: :codex, credential_kind: :api_key})
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/settings/agents")
      render_async(view)
      assert has_element?(view, "#agent-card-claude.default")
      assert has_element?(view, "#agent-menu-claude-menu #remove-claude-api_key")
      refute render(view) =~ "open tracks"

      view |> element("#make-default-codex") |> render_click()
      render_async(view)
      assert has_element?(view, "#agent-card-codex.default", "Default for new projects")
      assert Repo.get!(User, user.id).agent == :codex
    end

    test "the default model for new threads is behind its own disclosure", %{conn: conn} do
      user = insert_user()
      stub(Inference, :held, fn _ -> {:ok, [{:claude, :api_key}]} end)

      catalog = %Ravix.Fountain.Shapes.Catalog{
        runtimes: ["claude"],
        models: %{"claude" => ["anthropic/claude-sonnet-5"]}
      }

      stub(Ravix.Fountain, :client, fn -> FakeTransport.client([], verify: false) end)
      stub(Ravix.MachineCache, :catalog, fn _ -> {:ok, catalog} end)
      stub(Inference, :usable?, fn _, runtime, _ -> {:ok, runtime == "claude"} end)

      {:ok, view, _} = live(log_in_user(conn, user), "/settings/agents")
      # What is held, then the choices it allows: one read after the other.
      render_async(view)
      render_async(view)
      assert has_element?(view, "#agent-manage-toggle", "Default model for new threads")
      assert has_element?(view, "#agent-manage[hidden] #thread-default-form")
      view |> element("#agent-manage-toggle") |> render_click()
      refute has_element?(view, "#agent-manage[hidden]")
    end

    test "a revoked session cannot connect from the page", %{conn: conn} do
      reject(&Inference.connect/2)
      {token, session} = insert_session(insert_user())
      conn = Plug.Test.init_test_session(conn, session_token: token)
      {:ok, view, _} = live(conn, "/settings/agents")
      view |> element("#agent-claude") |> render_click()

      Repo.delete!(session)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> form("#credential-form", credential: [value: "k"]) |> render_submit()
    end

    test "a revoked session cannot remove from the page", %{conn: conn} do
      user = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "s")
      stub(Inference, :held, fn _ -> {:ok, [{:claude, :api_key}]} end)
      reject(&Inference.disconnect/3)
      {token, session} = insert_session(user)
      conn = Plug.Test.init_test_session(conn, session_token: token)
      {:ok, view, _} = live(conn, "/settings/agents")
      render_async(view)

      Repo.delete!(session)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> element("#remove-claude-api_key") |> render_click()
    end

    test "the panel acts for the signed-in person only, whatever the page is sent", %{
      conn: conn
    } do
      me = insert_user()
      other = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "other")

      stub(Inference, :held, fn caller ->
        assert caller.id == me.id
        {:ok, []}
      end)

      expect(Inference, :connect, fn caller, %{agent: :claude} ->
        assert caller.id == me.id
        {:error, {:unprocessable, "invalid_credential", "That key was refused."}}
      end)

      {:ok, view, _} = live(log_in_user(conn, me), "/settings/agents")
      render_async(view)
      # Nothing the browser sends names a person: an extra id is ignored.
      render_click(view |> element("#agent-claude"), %{"user" => other.id, "agent" => "claude"})

      view
      |> form("#credential-form", credential: [value: "k"])
      |> render_submit(%{"user_id" => other.id})

      render_async(view)
      assert Repo.get!(User, other.id).credential_set_id == "other"
    end

    test "the page hands the panel its clock only while Agents is open", %{conn: conn} do
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
           poll_interval: 60
         }}
      end)

      # One poll: the tick while Agents is open. The one after leaving is
      # dropped, since the panel is gone with the page.
      expect(Inference, :poll_link, 1, fn _, %Inference.Link{attempt_id: "att-1"} ->
        {:ok, :pending}
      end)

      {:ok, view, _} = live(log_in_user(conn, user), "/settings/agents")
      view |> element("#connect-codex-subscription") |> render_click()
      view |> element("#chatgpt-connect") |> render_click()
      assert render_async(view) =~ "WXYZ-1234"

      send(view.pid, {:agent_panel, "settings-agent-panel", :poll_link})
      render(view)
      assert render_async(view) =~ "WXYZ-1234"

      render_patch(view, "/settings/profile")
      send(view.pid, {:agent_panel, "settings-agent-panel", :poll_link})
      render(view)
      render_async(view)
      refute has_element?(view, "#settings-agent-panel")
    end
  end

  test "revoking the session leaves a personal settings page", %{conn: conn} do
    {token, session} = insert_session(insert_user())

    {:ok, view, _} =
      live(Plug.Test.init_test_session(conn, %{session_token: token}), "/settings/profile")

    Accounts.end_session(session.token_hash)
    assert_redirect(view, "/login", 1_000)
  end
end

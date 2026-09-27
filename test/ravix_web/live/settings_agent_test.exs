defmodule RavixWeb.Live.SettingsAgentTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Accounts.Inference
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.{Projects, Repo}

  setup :verify_on_exit!

  setup do
    user = insert_user(agent: :claude, credential_set_id: "set-owner")
    project = insert_project(user: user)

    stub(Inference, :usable_agents, fn caller ->
      assert caller.id == user.id
      {:ok, [:claude]}
    end)

    stub(Inference, :held, fn _ -> {:ok, [{:claude, :subscription}]} end)
    stub(Inference, :subscription, fn _ -> {:ok, nil} end)
    stub(Inference, :link_status, fn _ -> {:ok, %{enabled?: true, pending: nil}} end)

    stub(Projects, :settings, fn caller, id ->
      assert caller.id == user.id
      assert id == project.id

      {:ok,
       %{
         name: project.name,
         runtime: "claude",
         model: "",
         instructions: "",
         setup_script: "",
         packages: %{},
         env_keys: [],
         vault_keys: [],
         catalog: Catalog.empty()
       }}
    end)

    %{user: user, project: project}
  end

  defp open(conn, user, project) do
    # Await the actual tasks; a 100ms default races loaded coverage/browser runs.
    {:ok, view, _} = live(conn, "/p/#{project.id}")
    render_async(view, 2_000)
    render_click(view, "dialog", %{name: "settings"})
    render_async(view, 2_000)
    assert has_element?(view, "#settings-dialog")
    {view, user}
  end

  test "owner connects the selected agent inline and continues into the rebuild confirmation",
       ctx do
    {view, _} = open(log_in_user(ctx.conn, ctx.user), ctx.user, ctx.project)
    assert has_element?(view, "#settings-agent-claude[aria-pressed=true]", "Connected")
    assert has_element?(view, "#settings-dialog", "subscription or API key")
    assert has_element?(view, "#settings-agent-codex", "Not connected — connect to use")
    view |> element("#settings-agent-codex") |> render_click()
    render_async(view)
    assert has_element?(view, "#settings-connect-codex #chatgpt-connect")
    refute has_element?(view, "#settings-connect-codex #agent-claude")
    assert has_element?(view, "[data-switch-agent][disabled]")

    view
    |> form("#agent-settings-form", settings: [instructions: "Keep this draft"])
    |> render_change()

    view |> element("#kind-api_key") |> render_click()

    expect(Inference, :connect, fn caller, attrs ->
      assert caller.id == ctx.user.id
      assert attrs == %{agent: :codex, kind: :api_key, value: "sk-test"}
      {:ok, ctx.user}
    end)

    view |> form("#credential-form", credential: [value: "sk-test"]) |> render_submit()
    render_async(view)
    assert has_element?(view, "#settings-agent-codex[aria-pressed=true]", "Connected")
    assert has_element?(view, "#settings-runtime[value=codex]")
    assert has_element?(view, "#settings-instructions", "Keep this draft")
    refute has_element?(view, "#settings-connect-codex")
    refute has_element?(view, "[data-switch-agent][disabled]")
    refute render(view) =~ "sk-test"
    view |> form("#agent-settings-form") |> render_submit()
    render_async(view)
    assert has_element?(view, "#agent-switch-confirmation", "This closes 0 open tracks")

    expect(Projects, :update_settings, fn caller, id, attrs ->
      assert caller.id == ctx.user.id
      assert id == ctx.project.id
      assert attrs["runtime"] == "codex"
      assert attrs["rebuild"] == true
      assert attrs["instructions"] == "Keep this draft"
      {:error, {:conflict, "agent_not_connected", "Connect this agent first."}}
    end)

    view |> element("#confirm-agent-switch") |> render_click()
    render_async(view)
    assert has_element?(view, "#agent-settings-form .error", "Connect this agent first.")
  end

  test "connected choice needs no panel; unavailable status can be retried without losing selection",
       ctx do
    stub(Inference, :usable_agents, fn _ -> {:ok, [:claude, :codex]} end)
    {view, _} = open(log_in_user(ctx.conn, ctx.user), ctx.user, ctx.project)
    view |> element("#settings-agent-codex") |> render_click()
    refute has_element?(view, "#settings-connect-codex")
    assert has_element?(view, "#settings-agent-codex", "Connected")
    render_click(view, "dismiss")
    stub(Inference, :usable_agents, fn _ -> {:error, {:unavailable, "Provider unavailable"}} end)
    render_click(view, "dialog", %{name: "settings"})
    render_async(view)
    assert has_element?(view, "#settings-agent-claude", "Connection status unavailable")
    refute render(view) =~ "Not connected — connect to use"
    view |> element("#settings-agent-codex") |> render_click()
    stub(Inference, :usable_agents, fn _ -> {:ok, [:codex]} end)
    view |> element("[phx-click=refresh-settings-agents]") |> render_click()
    render_async(view)
    assert has_element?(view, "#settings-agent-codex[aria-pressed=true]", "Connected")
  end

  test "closing settings mid-sign-in drops polling, including after reopening", ctx do
    link = %Inference.Link{
      set_id: "set-owner",
      attempt_id: "attempt",
      user_code: "CODE",
      verification_url: "https://example.com",
      poll_interval: 60,
      trusted?: false
    }

    stub(Inference, :begin_link, fn _ -> {:ok, link} end)
    reject(&Inference.poll_link/2)
    {view, _} = open(log_in_user(ctx.conn, ctx.user), ctx.user, ctx.project)
    view |> element("#settings-agent-codex") |> render_click()
    render_async(view)
    view |> element("#chatgpt-connect") |> render_click()
    render_async(view)
    assert has_element?(view, "#chatgpt-code")
    {components, _, _} = :sys.get_state(view.pid).components

    {_, id, assigns, _, _} =
      Enum.find_value(components, fn {_, {_, id, _, _, _} = c} ->
        if String.starts_with?(id, "settings-connect-codex-"), do: c
      end)

    tick = {:agent_panel, id, {:poll_link, assigns.poll_token}}
    view |> element("#settings-agent-claude") |> render_click()
    send(view.pid, tick)
    render_async(view)
    view |> element("#settings-agent-codex") |> render_click()
    render_async(view)
    send(view.pid, tick)
    render_async(view)
    refute has_element?(view, "#chatgpt-code")
    render_click(view, "dismiss")
    send(view.pid, tick)
    render(view)
    refute has_element?(view, "#chatgpt-code")
    render_click(view, "dialog", %{name: "settings"})
    render_async(view)
    view |> element("#settings-agent-codex") |> render_click()
    render_async(view)
    send(view.pid, tick)
    render_async(view)
    refute has_element?(view, "#chatgpt-code")
  end

  test "visible settings forwards token-scoped polls and keeps selection on success", ctx do
    link = %Inference.Link{
      set_id: "set-owner",
      attempt_id: "fast",
      user_code: "CODE",
      verification_url: "https://example.com",
      poll_interval: 0,
      trusted?: false
    }

    expect(Inference, :begin_link, fn _ -> {:ok, link} end)

    expect(Inference, :poll_link, fn caller, ^link ->
      assert caller.id == ctx.user.id
      {:ok, ctx.user}
    end)

    {view, _} = open(log_in_user(ctx.conn, ctx.user), ctx.user, ctx.project)
    view |> element("#settings-agent-codex") |> render_click()
    render_async(view)
    view |> element("#chatgpt-connect") |> render_click()
    render_async(view)
    render_async(view)
    assert has_element?(view, "#settings-agent-codex[aria-pressed=true]", "Connected")
  end

  test "slow availability cannot overwrite a successful inline connection", ctx do
    parent = self()

    stub(Inference, :usable_agents, fn _ ->
      send(parent, {:reading_agents, self()})

      receive do
        :finish -> {:ok, [:claude]}
      end
    end)

    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.user), "/p/#{ctx.project.id}")
    render_async(view)
    render_click(view, "dialog", %{name: "settings"})
    assert_receive {:reading_agents, reader}
    monitor = Process.monitor(reader)
    view |> element("#settings-agent-codex") |> render_click()
    view |> element("#kind-api_key") |> render_click()
    expect(Inference, :connect, fn _, _ -> {:ok, ctx.user} end)
    view |> form("#credential-form", credential: [value: "sk-test"]) |> render_submit()
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 1000
    render_async(view)
    assert has_element?(view, "#settings-agent-codex[aria-pressed=true]", "Connected")
  end

  test "discard restores saved settings and invalid or repeated choices retain the draft", ctx do
    {view, _} = open(log_in_user(ctx.conn, ctx.user), ctx.user, ctx.project)
    view |> form("#agent-settings-form", settings: [instructions: "Draft"]) |> render_change()
    view |> element("#settings-agent-claude") |> render_click()
    assert has_element?(view, "#settings-instructions", "Draft")
    view |> element("#settings-agent-codex") |> render_click(%{"agent" => "invalid"})
    assert has_element?(view, "#settings-agent-claude[aria-pressed=true]")
    view |> element("#settings-agent-codex") |> render_click()

    view
    |> with_target("div[data-phx-component]:has(#settings-sections)")
    |> render_hook("discard-agent", %{})

    assert has_element?(view, "#settings-agent-claude[aria-pressed=true]")
    refute has_element?(view, "#settings-connect-codex")
    refute has_element?(view, "#settings-instructions", "Draft")
  end

  for agents <- [[], [:claude, :codex]] do
    @agents agents
    test "members see the owner's agent and no settings/connect form when connected agents are #{inspect(agents)}",
         ctx do
      stub(Inference, :usable_agents, fn _ -> {:ok, @agents} end)
      member = insert_user()
      insert_project_member(ctx.project, member)
      {:ok, view, _} = live(log_in_user(ctx.conn, member), "/p/#{ctx.project.id}")
      render_async(view)

      assert has_element?(
               view,
               "#project-agent-owner",
               "This project runs on #{ctx.user.login}'s Claude Code; every turn uses their subscription or API key."
             )

      render_click(view, "dialog", %{name: "settings"})
      refute has_element?(view, "#settings-dialog")
      refute has_element?(view, "#credential-form")
      refute has_element?(view, "#chatgpt-connect")
      {:ok, stranger, _} = live(log_in_user(ctx.conn, insert_user()), "/p/#{ctx.project.id}")
      render_async(stranger)
      assert_patch(stranger, "/home")
      refute has_element?(stranger, "#project-agent-owner")
      render_click(stranger, "dialog", %{name: "settings"})
      refute has_element?(stranger, "#credential-form")
    end

    test "revoked session cannot choose or connect with availability #{inspect(agents)}", ctx do
      stub(Inference, :usable_agents, fn _ -> {:ok, @agents} end)
      {token, session} = insert_session(ctx.user)
      conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
      {view, _} = open(conn, ctx.user, ctx.project)
      reject(&Inference.connect/2)
      Repo.delete!(session)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> element("#settings-agent-codex") |> render_click()
    end
  end

  test "revoked session cannot submit the inline credential form", ctx do
    {token, session} = insert_session(ctx.user)
    conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
    {view, _} = open(conn, ctx.user, ctx.project)
    view |> element("#settings-agent-codex") |> render_click()
    render_async(view)
    view |> element("#kind-api_key") |> render_click()
    Repo.delete!(session)
    reject(&Inference.connect/2)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> form("#credential-form", credential: [value: "sk-test"]) |> render_submit()
  end
end

defmodule RavixWeb.Live.NewProjectTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Accounts, Projects}
  alias Ravix.Accounts.Inference

  setup :verify_on_exit!

  setup do
    # Establish ownership before the LiveView captures its first event.
    PostHog.Test.all_captured()

    user =
      insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "set-owner")

    stub(Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)
    stub(Inference, :held, fn _ -> {:ok, [{:claude, :subscription}]} end)
    stub(Inference, :subscription, fn _ -> {:ok, nil} end)
    stub(Inference, :link_status, fn _ -> {:ok, %{enabled?: true, pending: nil}} end)
    stub(Accounts, :capabilities, fn -> %{github: true} end)

    stub(Projects, :repos, fn _, _ ->
      {:ok,
       %{
         repos: [
           %{full_name: "zebra/api", installation_id: 42},
           %{full_name: "acme/web", installation_id: 42}
         ],
         installations: [%{account: "acme", id: 42}],
         selected: 42
       }}
    end)

    %{user: user}
  end

  defp open(conn, user) do
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)
    render_click(view, "dialog", %{name: "new-project"})
    render_async(view)
    view
  end

  defp events(name), do: Enum.filter(PostHog.Test.all_captured(), &(&1.event == name))

  test "picker exposure counts openings, not renders, choices, edits or refreshes", %{
    conn: conn,
    user: user
  } do
    view = open(conn, user)
    assert length(events("agent picker shown unconnected")) == 1
    render(view)
    view |> form("#new-project-form", new_project: [name: "Draft"]) |> render_change()
    render_click(view, "refresh-project-agents")
    render_async(view)
    assert length(events("agent picker shown unconnected")) == 1
    render_click(view, "dismiss")
    render_click(view, "dialog", %{name: "new-project"})
    render_async(view)
    assert length(events("agent picker shown unconnected")) == 2
  end

  test "a dismissed picker does not record a late availability answer", %{conn: conn, user: user} do
    owner = self()

    expect(Inference, :usable_agents, fn _ ->
      send(owner, {:reading_agents, self()})

      receive do
        :finish -> {:ok, [:claude]}
      end
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)
    render_click(view, "dialog", %{name: "new-project"})
    assert_receive {:reading_agents, task}
    render_click(view, "dismiss")
    send(task, :finish)
    render_async(view)
    assert events("agent picker shown unconnected") == []
  end

  test "fully connected picker does not report an unconnected option", %{conn: conn, user: user} do
    stub(Inference, :usable_agents, fn _ -> {:ok, [:claude, :codex]} end)
    view = open(conn, user)
    render(view)
    assert events("agent picker shown unconnected") == []
  end

  test "failed inline attempt counts once, duplicate submit is ignored, retry completes once", %{
    conn: conn,
    user: user
  } do
    owner = self()

    expect(Inference, :connect, fn _, _ ->
      send(owner, {:connecting, self()})

      receive do
        :finish -> {:error, {:unprocessable, "bad_credential", "Try again"}}
      end
    end)

    view = open(conn, user)
    view |> element("#project-agent-codex") |> render_click()
    view |> element("#kind-api_key") |> render_click()
    form(view, "#credential-form", credential: [value: "private-key"]) |> render_submit()
    assert_receive {:connecting, task}
    form(view, "#credential-form", credential: [value: "private-key"]) |> render_submit()
    assert length(events("inline connect started")) == 1
    assert events("inline connect completed") == []
    send(task, :finish)
    render_async(view)
    assert has_element?(view, "#credential-form", "Try again")
    expect(Inference, :connect, fn _, _ -> {:ok, user} end)
    form(view, "#credential-form", credential: [value: "private-key"]) |> render_submit()
    render_async(view)
    render(view)
    assert length(events("inline connect started")) == 2
    assert [%{properties: properties}] = events("inline connect completed")
    assert properties["ravix.agent"] == "codex"
    assert properties["ravix.paid_by"] == "api_key"
    refute inspect(PostHog.Test.all_captured()) =~ "private-key"
  end

  test "Claude-only owner sees Codex and can connect it without losing the draft", %{
    conn: conn,
    user: user
  } do
    view = open(conn, user)
    assert has_element?(view, "#project-agent-claude[aria-pressed=true]", "Connected")

    assert has_element?(
             view,
             "#project-agent-codex:not([disabled])",
             "Not connected - connect to use"
           )

    view
    |> form("#new-project-form", new_project: [name: "Keep this", repo: "acme/web"])
    |> render_change()

    view |> element("#project-agent-codex") |> render_click()
    render_async(view)
    assert has_element?(view, "#project-connect-codex #chatgpt-connect")
    refute has_element?(view, "#project-connect-codex #agent-claude")
    assert has_element?(view, "#new-project-form button[disabled]")
    view |> element("#kind-api_key") |> render_click()

    expect(Inference, :connect, fn caller, attrs ->
      assert caller.id == user.id
      assert attrs == %{agent: :codex, kind: :api_key, value: "sk-test"}
      {:ok, user}
    end)

    view |> form("#credential-form", credential: [value: "sk-test"]) |> render_submit()
    render_async(view)
    assert has_element?(view, "#project-agent-codex[aria-pressed=true]", "Connected")
    assert has_element?(view, "#project-name[value='Keep this']")
    assert has_element?(view, "#project-repo[value='acme/web']")
    refute has_element?(view, "#new-project-form button[disabled]")
    refute has_element?(view, "#project-connect-codex")
    refute render(view) =~ "sk-test"
    assert length(events("inline connect started")) == 1
    assert length(events("inline connect completed")) == 1
  end

  test "onboarding uses the identical ordered fields and keeps inline connection on the project step",
       %{conn: conn, user: user} do
    workspace = open(conn, user)
    {:ok, welcome, _} = live(log_in_user(conn, user), "/welcome/project")
    render_async(welcome)

    fields = fn view ->
      render(view)
      |> LazyHTML.from_document()
      |> LazyHTML.query(".new-project-fields [id]")
      |> LazyHTML.attribute("id")
    end

    assert fields.(workspace) -- ["new-project-form"] ==
             fields.(welcome) -- ["first-project-form"]

    assert Enum.find_index(fields.(welcome), &(&1 == "project-repo")) <
             Enum.find_index(fields.(welcome), &(&1 == "project-name"))

    welcome |> form("#first-project-form", new_project: [name: "First"]) |> render_change()
    welcome |> element("#project-agent-codex") |> render_click()
    render_async(welcome)
    send(welcome.pid, {:agent_connected, user, :codex})
    render(welcome)

    assert has_element?(
             welcome,
             "#welcome-project #project-agent-codex[aria-pressed=true]",
             "Connected"
           )

    assert has_element?(welcome, "#project-name[value=First]")
    refute has_element?(welcome, "#first-project-form button[disabled]")
  end

  test "no credentials chooses no agent; unavailable default chooses another usable agent", %{
    conn: conn,
    user: user
  } do
    stub(Inference, :usable_agents, fn _ -> {:ok, []} end)
    view = open(conn, user)
    refute has_element?(view, "#project-runtime [aria-pressed=true]")
    assert has_element?(view, "#new-project-form button[disabled]")
    stub(Inference, :usable_agents, fn _ -> {:ok, [:codex]} end)
    render_click(view, "refresh-project-agents")
    render_async(view)
    assert has_element?(view, "#project-agent-codex[aria-pressed=true]", "Connected")
    refute has_element?(view, "#new-project-form button[disabled]")
  end

  test "provider error is distinct from not connected and retry preserves fields", %{
    conn: conn,
    user: user
  } do
    stub(Inference, :usable_agents, fn _ -> {:error, {:unavailable, "Try the provider again"}} end)

    view = open(conn, user)
    assert has_element?(view, "#project-agent-error", "Try the provider again")
    refute render(view) =~ "Not connected - connect to use"
    view |> form("#new-project-form", new_project: [name: "Draft"]) |> render_change()
    stub(Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)
    render_click(view, "refresh-project-agents")
    render_async(view)
    assert has_element?(view, "#project-name[value=Draft]")
    assert has_element?(view, "#project-agent-claude[aria-pressed=true]")
  end

  test "GitHub and scratch cards have different starting states and repository choices filter in name order",
       %{conn: conn, user: user} do
    view = open(conn, user)

    assert render(view)
           |> LazyHTML.from_document()
           |> LazyHTML.query("#project-repositories option")
           |> LazyHTML.attribute("value") == ["acme/web", "zebra/api"]

    view |> form("#new-project-form", new_project: [repo: "API"]) |> render_change()
    assert has_element?(view, "#project-repositories option[value='zebra/api']")
    refute has_element?(view, "#project-repositories option[value='acme/web']")
    render_click(view, "dismiss")
    view |> element(".home-action", "Quick start") |> render_click()
    refute has_element?(view, "#project-repo")
    render_click(view, "dismiss")
    view |> element(".home-action", "Open a GitHub project") |> render_click()
    assert has_element?(view, "#project-repo")
    assert has_element?(view, "#project-name[placeholder=\"Defaults to the repository's name\"]")
  end

  test "authoritative refusal appears on the picker and preserves the form", %{
    conn: conn,
    user: user
  } do
    expect(Projects, :create, fn _, _ ->
      {:error,
       {:conflict, "agent_not_connected",
        "Connect Claude Code before creating a project with it."}}
    end)

    view = open(conn, user)
    view |> form("#new-project-form", new_project: [name: "Saved"]) |> render_submit()
    render_async(view)
    assert has_element?(view, "#project-agent-error", "Connect Claude Code")
    assert has_element?(view, "#project-name[value=Saved]")
  end

  test "closing a dialog discards its poll ticks, including after reopening", %{
    conn: conn,
    user: user
  } do
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
    view = open(conn, user)
    view |> element("#project-agent-codex") |> render_click()
    render_async(view)
    view |> element("#chatgpt-connect") |> render_click()
    render_async(view)
    assert has_element?(view, "#chatgpt-code")
    {components, _, _} = :sys.get_state(view.pid).components

    {_, panel_id, assigns, _, _} =
      Enum.find_value(components, fn {_, {_, id, _, _, _} = component} ->
        if String.starts_with?(id, "project-connect-codex-"), do: component
      end)

    old_tick = {:agent_panel, panel_id, {:poll_link, assigns.poll_token}}
    render_click(view, "dismiss")
    send(view.pid, old_tick)
    render(view)
    refute has_element?(view, "#chatgpt-code")
    render_click(view, "dialog", %{name: "new-project"})
    render_async(view)
    view |> element("#project-agent-codex") |> render_click()
    render_async(view)
    send(view.pid, old_tick)
    render_async(view)
  end

  test "inline ChatGPT polling completes on the project step", %{conn: conn, user: user} do
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
      assert caller.id == user.id
      {:ok, user}
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/welcome/project")
    render_async(view)
    view |> element("#project-agent-codex") |> render_click()
    render_async(view)
    view |> element("#chatgpt-connect") |> render_click()
    render_async(view)
    render_async(view)

    assert length(events("inline connect started")) == 1
    assert length(events("inline connect completed")) == 1

    assert has_element?(
             view,
             "#welcome-project #project-agent-codex[aria-pressed=true]",
             "Connected"
           )
  end

  test "a slow availability read cannot undo a successful connection", %{conn: conn, user: user} do
    owner = self()

    stub(Inference, :usable_agents, fn _ ->
      send(owner, {:availability_started, self()})

      receive do
        :finish -> {:ok, [:claude]}
      end
    end)

    expect(Inference, :connect, fn _, _ -> {:ok, user} end)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)
    render_click(view, "dialog", %{name: "new-project"})
    assert_receive {:availability_started, reader}
    monitor = Process.monitor(reader)
    view |> element("#project-agent-codex") |> render_click()
    view |> element("#kind-api_key") |> render_click()
    view |> form("#credential-form", credential: [value: "sk-test"]) |> render_submit()
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 1000
    render_async(view)
    assert has_element?(view, "#project-agent-codex[aria-pressed=true]", "Connected")
    refute has_element?(view, "#new-project-form button[disabled]")
  end
end

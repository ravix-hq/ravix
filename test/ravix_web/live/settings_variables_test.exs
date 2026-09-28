defmodule RavixWeb.Live.SettingsVariablesTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.Fountain
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Projects.EnvironmentVariables.Row

  setup :verify_on_exit!

  setup ctx do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, env} = Agent.start_link(fn -> %{} end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    stub(Ravix.MachineCache, :machine_of, fn _, _ -> {:ok, nil} end)
    stub(Fountain, :get_environment, fn _, _ -> {:ok, %{"env_vars" => Agent.get(env, & &1)}} end)

    stub(Fountain, :update_environment, fn _, _, %{env_vars: vars} ->
      Agent.update(env, fn _ -> vars end)
      {:ok, %{"env_vars" => vars}}
    end)

    stub(Fountain, :secret_keys, fn _, _, _ -> {:ok, []} end)
    stub(Fountain, :catalog, fn _ -> {:ok, Catalog.empty()} end)
    stub(Fountain, :client, fn -> Fountain.Client.new("https://fountain.test", "test") end)
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)
    {:ok, view, _} = live(log_in_user(ctx.conn, user), "/p/#{project.id}")
    render_async(view, 2_000)
    render_click(view, "dialog", %{name: "settings"})
    render_async(view, 2_000)
    %{view: view, user: user, project: project, env: env}
  end

  test "row inspection keeps names but hides values" do
    row = %Row{key: "PORT", value: "hidden-diagnostic-value"}
    assert inspect(row) =~ "PORT"
    refute inspect(row) =~ "hidden-diagnostic-value"
  end

  test "owner adds, edits and removes visible variables", %{view: view, env: env} do
    view |> element("[phx-click=add-env-var]") |> render_click()

    view
    |> form("#env-vars-form", env_vars: %{"0" => %{key: "PORT", value: "4100"}})
    |> render_submit()

    render_async(view, 2_000)
    assert Agent.get(env, & &1) == %{"PORT" => "4100"}
    assert has_element?(view, "textarea#env-var-value-0", "4100")

    view
    |> form("#env-vars-form", env_vars: %{"0" => %{key: "PORT", value: "4200\nnext line"}})
    |> render_submit()

    render_async(view, 2_000)
    assert Agent.get(env, & &1) == %{"PORT" => "4200\nnext line"}
    view |> element("[phx-click=remove-env-var]") |> render_click()
    view |> form("#env-vars-form") |> render_submit()
    render_async(view, 2_000)
    assert Agent.get(env, & &1) == %{}
    refute has_element?(view, "#env-var-key-0")
  end

  test "auth-name errors keep entered rows for correction", %{view: view, env: env} do
    view |> element("[phx-click=add-env-var]") |> render_click()

    view
    |> form("#env-vars-form", env_vars: %{"0" => %{key: "OPENAI_API_KEY", value: "test-value"}})
    |> render_submit()

    render_async(view, 2_000)
    assert render(view) =~ "Use a secret if you intend to override billing"
    assert has_element?(view, "#env-var-key-0[value=OPENAI_API_KEY]")
    assert has_element?(view, "#env-var-value-0", "test-value")
    assert Agent.get(env, & &1) == %{}
  end

  test "stale dialog refuses to replace a newer map", %{view: view, env: env} do
    Agent.update(env, fn _ -> %{"PORT" => "newer"} end)
    view |> element("[phx-click=add-env-var]") |> render_click()

    view
    |> form("#env-vars-form", env_vars: %{"0" => %{key: "PORT", value: "old edit"}})
    |> render_submit()

    render_async(view, 2_000)
    assert render(view) =~ "Variables changed since you opened settings. Reload and try again."
    assert Agent.get(env, & &1) == %{"PORT" => "newer"}
  end

  test "missing row value reports validation instead of crashing", %{view: view, env: env} do
    view
    |> with_target(component(view))
    |> render_hook("save-env-vars", %{
      "env_vars" => %{"0" => %{"key" => "PORT"}}
    })

    render_async(view, 2_000)
    assert render(view) =~ "Each variable needs a name and a string value."
    assert Agent.get(env, & &1) == %{}
  end

  defp component(view) do
    view
    |> element("#settings-sections")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#settings-sections")
    |> LazyHTML.attribute("data-component")
    |> hd()
    |> String.to_integer()
  end

  test "discard restores saved rows and revoked ownership cannot save", ctx do
    ctx.view |> element("[phx-click=add-env-var]") |> render_click()
    ctx.view |> with_target(component(ctx.view)) |> render_hook("discard-env-vars", %{})
    refute has_element?(ctx.view, "#env-var-key-0")
    ctx.view |> element("[phx-click=add-env-var]") |> render_click()
    # Same event-time access gate as every settings mutation.
    expect(Ravix.Accounts.Access, :project_of, fn _, _ -> {:error, :not_found} end)

    ctx.view
    |> form("#env-vars-form", env_vars: %{"0" => %{key: "PORT", value: "9"}})
    |> render_submit()

    assert Agent.get(ctx.env, & &1) == %{}
  end
end

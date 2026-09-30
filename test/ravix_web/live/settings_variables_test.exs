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

    stub(Ravix.Projects, :rebuild, fn _, _ ->
      {:ok, %Ravix.Projects.Machine.Rebuild{removed: [], failed: []}}
    end)

    render_patch(view, "/p/#{project.id}/settings/machine")
    render_async(view, 2_000)
    %{view: view, user: user, project: project, env: env}
  end

  test "row inspection keeps names but hides values" do
    row = %Row{key: "PORT", value: "hidden-diagnostic-value"}
    assert inspect(row) =~ "PORT"
    refute inspect(row) =~ "hidden-diagnostic-value"
  end

  # RAV-74: variables are a part of the Machine page, saved with the rest
  # of it behind one "Save & rebuild".
  test "owner adds, edits and removes visible variables", %{view: view, env: env} do
    add(view)
    save(view, env_vars: %{"0" => %{key: "PORT", value: "4100"}})
    assert Agent.get(env, & &1) == %{"PORT" => "4100"}
    assert has_element?(view, "textarea#env-var-value-0", "4100")

    view
    |> form("#machine-form", env_vars: %{"0" => %{key: "PORT", value: "4200\nnext line"}})
    |> render_submit()

    render_async(view, 2_000)
    assert has_element?(view, "#machine-review li", "1 variable changed")
    view |> form("#machine-form") |> put_submitter("#confirm-machine") |> render_submit()
    render_async(view, 2_000)
    assert Agent.get(env, & &1) == %{"PORT" => "4200\nnext line"}
    view |> element("button[aria-label='Remove variable 1']") |> render_click()
    save(view, %{})
    assert Agent.get(env, & &1) == %{}
    refute has_element?(view, "#env-var-key-0")
  end

  test "auth-name errors keep entered rows for correction", %{view: view, env: env} do
    add(view)

    view
    |> form("#machine-form", env_vars: %{"0" => %{key: "OPENAI_API_KEY", value: "test-value"}})
    |> render_submit()

    assert render(view) =~ "Use a secret if you intend to override billing"
    refute has_element?(view, "#machine-review")
    assert has_element?(view, "#env-var-key-0[value=OPENAI_API_KEY]")
    assert has_element?(view, "#env-var-value-0", "test-value")
    assert Agent.get(env, & &1) == %{}
  end

  test "stale page refuses to replace a newer map", %{view: view, env: env} do
    Agent.update(env, fn _ -> %{"PORT" => "newer"} end)
    add(view)
    save(view, env_vars: %{"0" => %{key: "PORT", value: "old edit"}})
    assert render(view) =~ "Variables changed since you opened settings. Reload and try again."
    assert Agent.get(env, & &1) == %{"PORT" => "newer"}
  end

  test "missing row value reports validation instead of crashing", %{view: view, env: env} do
    view
    |> element("#machine-form")
    |> render_submit(%{"env_vars" => %{"0" => %{"key" => "PORT"}}})

    assert render(view) =~ "Each variable needs a name and a string value."
    assert Agent.get(env, & &1) == %{}
  end

  test "discard restores saved rows and revoked ownership cannot save", ctx do
    add(ctx.view)
    ctx.view |> with_target(component(ctx.view)) |> render_click("discard-machine", %{})
    refute has_element?(ctx.view, "#env-var-key-0")
    add(ctx.view)
    # Same event-time access gate as every settings mutation.
    expect(Ravix.Accounts.Access, :project_of, fn _, _ -> {:error, :not_found} end)

    ctx.view
    |> form("#machine-form", env_vars: %{"0" => %{key: "PORT", value: "9"}})
    |> render_submit()

    refute has_element?(ctx.view, "#machine-review")
    assert Agent.get(ctx.env, & &1) == %{}
  end

  defp add(view), do: view |> element("button", "Add variable") |> render_click()

  defp save(view, params) do
    view |> form("#machine-form", params) |> render_submit()
    render_async(view, 2_000)
    view |> form("#machine-form", params) |> put_submitter("#confirm-machine") |> render_submit()
    render_async(view, 2_000)
  end

  # The page component, as the unsaved-changes bar's Discard targets it.
  defp component(view) do
    view
    |> element("#project-machine")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#project-machine")
    |> LazyHTML.attribute("data-discard-target")
    |> hd()
    |> String.to_integer()
  end
end

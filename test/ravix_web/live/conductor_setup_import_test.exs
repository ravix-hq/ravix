defmodule RavixWeb.Live.ConductorSetupImportTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  import Ecto.Query

  alias Ravix.Fountain
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.GitHubFake, as: GH
  alias Ravix.Previews

  setup :verify_on_exit!

  setup ctx do
    user = insert_user()

    project =
      insert_project(
        user: user,
        repo_full_name: "org/repo",
        installation_id: 8,
        default_branch: "main"
      )

    {:ok, env} =
      Agent.start_link(fn -> %{"setup_script" => "existing setup", "env_vars" => %{}} end)

    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    stub(Ravix.MachineCache, :machine_of, fn _, _ -> {:ok, nil} end)
    stub(Fountain, :get_environment, fn _, _ -> {:ok, Agent.get(env, & &1)} end)

    stub(Fountain, :update_environment, fn _, _, attrs ->
      Agent.update(
        env,
        &Map.merge(&1, Map.new(attrs, fn {key, value} -> {to_string(key), value} end))
      )

      {:ok, Agent.get(env, & &1)}
    end)

    stub(Fountain, :secret_keys, fn _, _, _ -> {:ok, []} end)
    stub(Fountain, :catalog, fn _ -> {:ok, Catalog.empty()} end)
    stub(Fountain, :client, fn -> Fountain.Client.new("https://fountain.test", "test") end)
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)

    stub(Ravix.Projects, :rebuild, fn _, _ ->
      {:ok, %Ravix.Projects.Machine.Rebuild{removed: [], failed: []}}
    end)

    {:ok, _} =
      Previews.set_defaults(user, project.id, %{
        command: "existing run --port $PORT",
        directory: ".",
        readiness_path: "/ready",
        stop_command: "cleanup"
      })

    app = GH.app()
    stub(Ravix.Config, :github, fn -> app end)
    routes(app)
    conn = log_in_user(ctx.conn, user)
    {:ok, view, _} = live(conn, "/p/#{project.id}")
    render_async(view)
    render_patch(view, "/p/#{project.id}/settings/machine")
    render_async(view)
    %{view: view, user: user, project: project, env: env, app: app}
  end

  test "discover and selecting nothing preserve entered settings and saved configuration", ctx do
    edit(ctx.view, "entered setup", "entered run --port $PORT")
    discover(ctx.view)
    apply_selection(ctx.view, %{})
    assert form_value(ctx.view, "#settings-setup") == "entered setup"
    assert form_value(ctx.view, "#default-command") == "entered run --port $PORT"
    assert Agent.get(ctx.env, & &1)["setup_script"] == "existing setup"

    assert {:ok, %{command: "existing run --port $PORT"}} =
             Previews.defaults(ctx.user, ctx.project.id)
  end

  test "only selected fields are staged and the existing save persists setup and defaults", ctx do
    edit(ctx.view, "entered setup", "entered run --port $PORT")
    discover(ctx.view)
    apply_selection(ctx.view, %{run: "web"})
    assert form_value(ctx.view, "#settings-setup") == "entered setup"
    assert form_value(ctx.view, "#default-command") == "npm run dev -- --port $PORT"
    assert form_value(ctx.view, "#default-directory") == "apps/web"
    assert form_value(ctx.view, "#default-readiness") == "/ready"
    assert form_value(ctx.view, "#default-stop-command") == "cleanup"
    apply_selection(ctx.view, %{setup: "true"})
    assert form_value(ctx.view, "#settings-setup") == "npm ci"
    assert Agent.get(ctx.env, & &1)["setup_script"] == "existing setup"
    ctx.view |> form("#machine-form") |> render_submit()
    render_async(ctx.view)
    ctx.view |> form("#machine-form") |> put_submitter("#confirm-machine") |> render_submit()
    render_async(ctx.view)
    assert Agent.get(ctx.env, & &1)["setup_script"] == "npm ci"

    assert {:ok,
            %{
              command: "npm run dev -- --port $PORT",
              directory: "apps/web",
              readiness_path: "/ready",
              stop_command: "cleanup"
            }} = Previews.defaults(ctx.user, ctx.project.id)
  end

  test "discard restores saved settings after a selected import", ctx do
    discover(ctx.view)
    apply_selection(ctx.view, %{setup: "true", run: "web"})
    ctx.view |> with_target(settings_component(ctx.view)) |> render_click("discard-machine", %{})
    assert form_value(ctx.view, "#settings-setup") == "existing setup"
    assert form_value(ctx.view, "#default-command") == "existing run --port $PORT"
  end

  test "forged and local-only selections cannot replace entered values", ctx do
    edit(ctx.view, "entered setup", "entered run")
    discover(ctx.view)

    for id <- ["mac", "port", "forged"] do
      ctx.view
      |> element("#conductor-import-form")
      |> render_submit(%{"import" => %{"run" => id}})

      assert form_value(ctx.view, "#settings-setup") == "entered setup"
      assert form_value(ctx.view, "#default-command") == "entered run"
    end
  end

  test "provider failure keeps entered settings and permits rediscovery", ctx do
    edit(ctx.view, "entered setup", "entered run")

    GH.install([
      GH.token_route(ctx.app),
      {"GET", ~r{/contents/}, {500, %{message: "provider unavailable"}}}
    ])

    discover(ctx.view)
    refute has_element?(ctx.view, "#conductor-import-form")
    assert form_value(ctx.view, "#settings-setup") == "entered setup"
    routes(ctx.app)
    discover(ctx.view)
    assert has_element?(ctx.view, "#conductor-import-form")
  end

  test "revoked access rejects discovery and application", ctx do
    discover(ctx.view)
    expect(Ravix.Accounts.Access, :project_of, fn _, _ -> {:error, :not_found} end)
    apply_selection(ctx.view, %{setup: "true"})
    assert form_value(ctx.view, "#settings-setup") == "existing setup"
    expect(Ravix.Accounts.Access, :project_of, fn _, _ -> {:error, :not_found} end)
    discover(ctx.view)
    assert Agent.get(ctx.env, & &1)["setup_script"] == "existing setup"
  end

  test "revoked session cannot apply reviewed commands", ctx do
    discover(ctx.view)
    Ravix.Repo.delete_all(from(s in Ravix.Accounts.Session, where: s.user_id == ^ctx.user.id))

    assert {:error, {:redirect, %{to: "/login"}}} =
             ctx.view
             |> form("#conductor-import-form", import: %{setup: "true"})
             |> render_submit()

    assert Agent.get(ctx.env, & &1)["setup_script"] == "existing setup"
  end

  test "membership removal during async discovery refuses the result", ctx do
    test = self()

    GH.install([
      GH.token_route(ctx.app),
      {"GET", ~r{/contents/},
       fn conn ->
         send(test, {:reading, self()})

         receive do
           :continue -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{message: "missing"})
         end
       end}
    ])

    ctx.view |> element("#discover-conductor-setup") |> render_click()
    assert_receive {:reading, task}
    ctx.project |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Ravix.Repo.update!()
    send(task, :continue)

    for _ <- 1..2 do
      assert_receive {:reading, ^task}
      send(task, :continue)
    end

    render_async(ctx.view)
    refute has_element?(ctx.view, "#conductor-import-form")
  end

  defp discover(view) do
    view |> element("#discover-conductor-setup") |> render_click()
    render_async(view)
  end

  defp apply_selection(view, selection) do
    view |> form("#conductor-import-form", import: selection) |> render_submit()
    render(view)
  end

  defp edit(view, setup, run) do
    view
    |> form("#machine-form", settings: %{setup_script: setup}, preview_defaults: %{command: run})
    |> render_change()
  end

  defp form_value(view, selector) do
    node = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

    if LazyHTML.tag(node) == ["textarea"],
      do: LazyHTML.text(node),
      else: node |> LazyHTML.attribute("value") |> hd()
  end

  defp settings_component(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#project-machine")
    |> LazyHTML.attribute("data-discard-target")
    |> hd()
    |> String.to_integer()
  end

  defp routes(app) do
    text = ~S'''
    [scripts]
    setup = "npm ci"
    [scripts.run.web]
    command = "npm run dev -- --port $PORT"
    default = true
    options = { cwd = "apps/web" }
    [scripts.run.mac]
    command = "open Xcode.app"
    available_in = ["local"]
    [scripts.run.port]
    command = "npm dev --port $CONDUCTOR_PORT"
    '''

    GH.install([
      GH.token_route(app),
      {"GET", "/repos/org/repo/contents/.conductor/settings.toml",
       %{type: "file", encoding: "base64", size: byte_size(text), content: Base.encode64(text)}},
      {"GET", ~r{/contents/}, {404, %{message: "missing"}}}
    ])
  end
end

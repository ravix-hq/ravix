defmodule RavixWeb.WorkspaceManagementTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Accounts, People, Previews, Projects, Repo, Tracks}
  alias Ravix.Fountain.Client
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Hub.Event
  alias Ravix.Projects.Machine.Rebuild
  alias RavixWeb.Live.ThreadConnect

  setup :verify_on_exit!

  setup do
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude, :codex]} end)
    :ok
  end

  setup %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    %{view: view, user: user, project: project}
  end

  test "the new-track picker connects an owner inline without losing the branch draft", ctx do
    options = %{
      runtime: "claude",
      model: "anthropic/claude-opus-5",
      owner_login: ctx.user.login,
      owner?: true,
      runtimes: [
        %{runtime: "claude", connected: true, enabled: true, models: ["anthropic/claude-opus-5"]},
        %{runtime: "codex", connected: false, enabled: true, models: ["openai/gpt-6-astra"]}
      ]
    }

    stub(Tracks, :open_options, fn _, _ -> {:ok, options} end)
    stub(Ravix.Accounts.Inference, :held, fn _ -> {:ok, []} end)
    stub(Ravix.Accounts.Inference, :subscription, fn _ -> {:ok, nil} end)

    stub(Ravix.Accounts.Inference, :link_status, fn _ ->
      {:ok, %{enabled?: true, pending: nil}}
    end)

    render_click(ctx.view, "dialog", %{name: "new-track"})
    render_async(ctx.view)

    render_click(ctx.view, "edit", %{
      "new_track" => %{"title" => "keep-my-branch", "runtime" => "claude"}
    })

    ctx.view
    |> element("button[phx-click=connect-thread-agent][phx-value-runtime=codex]")
    |> render_click()

    render_async(ctx.view)
    ctx.view |> element(".thread-connections button[phx-value-kind=api_key]") |> render_click()

    expect(Ravix.Accounts.Inference, :connect, fn user, %{agent: :codex, value: "fixture"} ->
      {:ok, user}
    end)

    expect(Tracks, :open_options, fn _, _ ->
      {:ok, %{options | runtimes: Enum.map(options.runtimes, &%{&1 | connected: true})}}
    end)

    ctx.view
    |> form(".thread-connections form", credential: %{value: "fixture"})
    |> render_submit()

    render_async(ctx.view)
    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             ~s|#new-track-model-menu input[name="new_track[runtime]"][value=codex][checked]:not([disabled])|
           )

    assert :sys.get_state(ctx.view.pid).socket.assigns.track_form.params["title"] ==
             "keep-my-branch"

    refute has_element?(ctx.view, ".thread-connections form")
  end

  test "members cannot forge the inline owner connection action", ctx do
    member = insert_user()
    insert_project_member(ctx.project, member)
    options = %{owner?: true, runtimes: [%{runtime: "codex", connected: false, enabled: true}]}
    assert ThreadConnect.open(member, ctx.project.id, "codex", options) == nil
    assert ThreadConnect.open(ctx.user, ctx.project.id, "other", options) == nil
    connection = ThreadConnect.open(ctx.user, ctx.project.id, "codex", options)
    refute ThreadConnect.active?(member, ctx.project.id, connection, connection.id)
  end

  test "settings and composer use the same friendly catalog labels", ctx do
    labels = [
      {"openai/gpt-6-astra", "GPT-6 Astra"},
      {"openai/gpt-5.5", "GPT-5.5"},
      {"anthropic/claude-fable-5-1", "Claude Fable 5.1"},
      {"anthropic/claude-opus-5.5", "Claude Opus 5.5"}
    ]

    models = Enum.map(labels, &elem(&1, 0))
    catalog = %{Catalog.empty() | runtimes: ["claude"], models: %{"claude" => models}}
    settings(ctx, [catalog: catalog, model: hd(models)], "agent")
    render_async(ctx.view, 1000)

    for {id, label} <- labels do
      assert has_element?(ctx.view, "#settings-model option[value='#{id}']", label)

      composer =
        render_component(&RavixWeb.TrackLive.model_menu/1,
          model: id,
          project_model: hd(models),
          models: models,
          disabled: false
        )
        |> LazyHTML.from_document()

      assert composer |> LazyHTML.query("#model-trigger") |> LazyHTML.attribute("aria-label") == [
               label
             ]

      assert composer |> LazyHTML.query("#model-trigger .truncate") |> LazyHTML.text() == label

      for {choice, name} <- labels do
        value = if choice == hd(models), do: "", else: choice

        assert composer
               |> LazyHTML.query("[phx-value-model='#{value}'] .truncate")
               |> LazyHTML.text() == name
      end
    end
  end

  test "project creation keeps feedback until a failed task settles", ctx do
    test_pid = self()

    expect(Projects, :create, fn _, _ ->
      send(test_pid, {:creating, self()})

      receive do
        :finish -> {:error, {:unavailable, "Machine unavailable"}}
      end
    end)

    render_click(ctx.view, "dialog", %{name: "new-project"})
    render_async(ctx.view, 1000)
    ctx.view |> form("#new-project-form", new_project: [name: "Waiting"]) |> render_submit()
    assert_receive {:creating, task}, 1000
    assert has_element?(ctx.view, "#new-project-form [role=status]", "Creating project")
    assert has_element?(ctx.view, "#new-project-form button[disabled]", "Creating project")
    send(task, :finish)
    assert render_async(ctx.view, 1000) =~ "Machine unavailable"
    refute has_element?(ctx.view, "#new-project-form [role=status]")
    assert has_element?(ctx.view, "#project-name[value=Waiting]")
  end

  for outcome <- [:success, :error, :exit] do
    @outcome outcome
    @tag :capture_log
    test "repository loading feedback settles on #{@outcome}", ctx do
      test_pid = self()
      stub(Accounts, :capabilities, fn -> %{github: true} end)

      expect(Projects, :repos, fn _, _ ->
        send(test_pid, {:loading_repos, self()})

        receive do
          :finish ->
            case @outcome do
              :success -> {:ok, %{repos: [], installations: [], selected: nil}}
              :error -> {:error, {:unavailable, "GitHub unavailable"}}
              :exit -> exit(:provider_down)
            end
        end
      end)

      render_click(ctx.view, "dialog", %{name: "new-project"})
      assert_receive {:loading_repos, task}, 1000
      assert has_element?(ctx.view, "#new-project-dialog [role=status]", "Loading GitHub")
      assert has_element?(ctx.view, "#project-repo[aria-busy=true]")
      send(task, :finish)
      render_async(ctx.view, 1000)
      refute has_element?(ctx.view, "#new-project-dialog .loading-status")
      refute has_element?(ctx.view, "#project-repo[aria-busy=true]")
    end
  end

  test "repository selection retains installation ownership", ctx do
    stub(Accounts, :capabilities, fn -> %{github: true} end)

    expect(Projects, :repos, 2, fn user, id ->
      assert user.id == ctx.user.id
      assert id in [nil, 42]

      {:ok,
       %{
         repos: [%{full_name: "acme/app", installation_id: 42}],
         installations: [%{account: "acme", id: 42}],
         selected: 42
       }}
    end)

    expect(Projects, :create, fn user, attrs ->
      assert user.id == ctx.user.id

      assert attrs == %{
               "name" => "Selected",
               "repo" => "acme/app",
               "installation_id" => 42,
               "runtime" => "codex"
             }

      {:error, {:unavailable, "Provisioning is offline"}}
    end)

    render_click(ctx.view, "dialog", %{name: "new-project"})
    render_change(ctx.view, "installation", %{installation: "42"})
    render_change(ctx.view, "installation", %{installation: "bad-id"})

    render_click(ctx.view, "choose-project-agent", %{"agent" => "codex"})

    ctx.view
    |> form("#new-project-form",
      new_project: [name: "Selected", repo: "acme/app", runtime: "codex"]
    )
    |> render_change()

    render_click(ctx.view, "choose-project-agent", %{"agent" => "codex"})

    ctx.view
    |> form("#new-project-form",
      new_project: [name: "Selected", repo: "acme/app", runtime: "codex"]
    )
    |> render_submit()

    assert render_async(ctx.view, 1000) =~ "Provisioning is offline"
    assert has_element?(ctx.view, "input[name='new_project[name]'][value=Selected]")
    assert has_element?(ctx.view, "#project-agent-codex[aria-pressed=true]")
    refute has_element?(ctx.view, "#new-project-form button[disabled]")
  end

  for {kind, refs_kind, ref, expected} <- [
        {"blank", nil, nil, %{kind: "blank"}},
        {"branch", :branches, %{name: "release"}, %{kind: "branch", base: "release"}},
        {"pr", :pulls, %{number: 12, title: "Fix", head_ref: "feature/fix"},
         %{kind: "pr", number: 12, title: "Fix", base: "feature/fix"}},
        {"issue", :issues, %{number: 34, title: "Bug"},
         %{kind: "issue", number: 34, title: "Bug"}}
      ] do
    @kind kind
    @refs_kind refs_kind
    @ref ref
    @expected expected
    test "track creation preserves the #{@kind} origin", ctx do
      ref = @ref

      if ref do
        expect(Projects, :refs, fn user, id, kind ->
          assert {user.id, id, kind} == {ctx.user.id, ctx.project.id, @refs_kind}
          {:ok, [ref]}
        end)
      end

      expect(Tracks, :open, fn user, id, attrs ->
        assert {user.id, id} == {ctx.user.id, ctx.project.id}

        assert attrs == %{
                 title: if(@kind == "pr", do: nil, else: "Work"),
                 origin: @expected,
                 visibility: "project",
                 runtime: nil,
                 model: nil
               }

        {:error, {:conflict, "busy", "Machine is busy"}}
      end)

      render_click(ctx.view, "dialog", %{name: "new-track"})
      render_click(ctx.view, "origin", %{kind: @kind})
      # Listing a repository's branches, pulls or issues is a GitHub call,
      # and the form cannot be submitted against a ref that has not arrived.
      render_async(ctx.view, 1000)

      params =
        if ref,
          do: %{title: "Work", ref: to_string(ref[:number] || ref[:name])},
          else: %{title: "Work"}

      params = if @kind == "pr", do: Map.delete(params, :title), else: params
      ctx.view |> form("#new-track-form", new_track: params) |> render_submit()
      assert render_async(ctx.view, 1000) =~ "Machine is busy"
      refute has_element?(ctx.view, "#new-track-create[disabled]")
    end
  end

  test "branch validation errors keep the entered name beside the fixed prefix", ctx do
    # The mount-time rail may still be loading when this test enables Fountain.
    # Keep that read local too, rather than racing a request to fountain.test.
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

    stub(Ravix.Fountain, :client, fn ->
      Client.new("https://fountain.test", "key")
    end)

    stub(Ravix.Projects, :prepare_machine, fn _, _ -> :ok end)
    stub(Ravix.MachineCache, :machine_of, fn _, _ -> {:ok, nil} end)
    insert_track(project: ctx.project, branch: "ravix/spent", closed_at: DateTime.utc_now())
    render_click(ctx.view, "dialog", %{name: "new-track"})
    assert has_element?(ctx.view, "#branch-prefix", "ravix/")

    for {name, message} <- [
          {"two words", "Use a valid Git branch name"},
          {"spent", "including closed tracks"}
        ] do
      ctx.view |> form("#new-track-form", new_track: [title: name]) |> render_submit()
      # This checks validation, not scheduling latency under CI coverage.
      render_async(ctx.view, 5_000)
      assert has_element?(ctx.view, "#new-track-form .field p.error", message)
      assert has_element?(ctx.view, "#track-title[value='#{name}']")
      refute has_element?(ctx.view, "#new-track-create[disabled]")
    end
  end

  test "a duplicate PR branch has a visible error without an editable branch field", ctx do
    expect(Projects, :refs, fn _, _, :pulls ->
      {:ok, [%{number: 12, title: "Fix", head_ref: "feature/fix"}]}
    end)

    expect(Tracks, :open, fn _, _, %{origin: %{base: "feature/fix"}} ->
      {:error,
       {:unprocessable, "branch_taken", "That branch name is already used in this project."}}
    end)

    render_click(ctx.view, "dialog", %{name: "new-track"})
    render_click(ctx.view, "origin", %{kind: "pr"})
    render_async(ctx.view, 1000)
    refute has_element?(ctx.view, "#track-title")
    ctx.view |> form("#new-track-form", new_track: [ref: "12"]) |> render_submit()
    render_async(ctx.view, 1000)
    assert has_element?(ctx.view, "#new-track-form p.error", "That branch name is already used")
  end

  test "secrets are scoped and values are absent from the rendered page", ctx do
    settings(ctx, [], "machine")

    assert render(ctx.view) =~
             "Vault secrets are inserted into outgoing requests and stay off the machine."

    refute render(ctx.view) =~ "Fountain"

    expect(Projects, :update_settings, fn user, id, attrs ->
      assert {user.id, id} == {ctx.user.id, ctx.project.id}

      assert attrs == %{
               "secret" => %{"store" => "vault", "key" => "TOKEN", "value" => "private-value"}
             }

      {:ok, %{rev: 2}}
    end)

    expect(Projects, :rebuild, fn _, _ -> {:ok, %Rebuild{removed: ["agent"], failed: []}} end)
    add_secret(ctx.view)

    # The write is a Fountain round trip and runs off the page, and the
    # page hands its sentence on one message after the answer.
    save_machine(ctx.view,
      secrets: %{"1" => %{store: "vault", key: "TOKEN", value: "private-value"}}
    )

    html = render(ctx.view)
    assert html =~ "Machine settings saved"
    refute html =~ "private-value"
  end

  test "owner confirms a pending secret change explicitly and the form disappears", ctx do
    {:ok, generation} = Projects.Store.begin_secret_change(ctx.project.id)
    settings(ctx, [secrets_pending: true, secrets_generation: generation], "machine")
    assert has_element?(ctx.view, "#secret-confirmation-form", "Values cannot be checked here")
    reject(&Projects.update_settings/3)
    ctx.view |> form("#secret-confirmation-form") |> render_submit()
    assert render(ctx.view) =~ "Confirm that the previous secret change has finished first"
    assert Projects.Store.live_project(ctx.project.id).secrets_pending

    stub(Projects, :settings, fn _, _ ->
      {:ok,
       %Projects.Settings{
         env_vars: %{},
         name: ctx.project.name,
         runtime: "claude",
         model: "model",
         instructions: "",
         setup_script: "",
         packages: %{},
         env_keys: [],
         vault_keys: [],
         catalog: Catalog.empty()
       }}
    end)

    ctx.view |> form("#secret-confirmation-form", confirmed: "true") |> render_submit()
    render_async(ctx.view)
    refute Projects.Store.live_project(ctx.project.id).secrets_pending
    refute has_element?(ctx.view, "#secret-confirmation-form")
    assert render(ctx.view) =~ "Secret changes are unlocked"
    assert render(ctx.view) =~ "rebuild dedicated tracks"
  end

  test "a failed secret save immediately exposes confirmation without keeping its value", ctx do
    settings(ctx, [], "machine")

    expect(Projects, :update_settings, fn _, id, _ ->
      {:ok, _} = Projects.Store.begin_secret_change(id)
      {:error, {:unavailable, "The service did not confirm the change."}}
    end)

    # Nothing was saved, so nothing is rebuilt.
    reject(&Projects.rebuild/2)
    add_secret(ctx.view)

    save_machine(ctx.view,
      secrets: %{"1" => %{store: "vault", key: "TOKEN", value: "never-render-me"}}
    )

    assert render(ctx.view) =~ "Could not save secret TOKEN"

    assert has_element?(
             ctx.view,
             "#secret-confirmation-form",
             "previous secret change could not be confirmed"
           )

    refute render(ctx.view) =~ "never-render-me"
  end

  test "secret confirmation refuses stale forms and lost ownership", ctx do
    {:ok, generation} = Projects.Store.begin_secret_change(ctx.project.id)
    settings(ctx, [secrets_pending: true, secrets_generation: generation], "machine")
    :ok = Projects.Store.finish_secret_change(ctx.project.id, generation)
    {:ok, _} = Projects.Store.begin_secret_change(ctx.project.id)
    ctx.view |> form("#secret-confirmation-form", confirmed: "true") |> render_submit()
    render_async(ctx.view)
    assert render(ctx.view) =~ "Reopen Settings"
    assert Projects.Store.live_project(ctx.project.id).secrets_pending
    Repo.update!(Ecto.Changeset.change(ctx.project, user_id: insert_user().id))
    ctx.view |> form("#secret-confirmation-form", confirmed: "true") |> render_submit()
    assert render(ctx.view) =~ "No such thing here"
    assert Projects.Store.live_project(ctx.project.id).secrets_pending
  end

  test "revoked session cannot confirm a pending secret change", ctx do
    {token, session} = insert_session(ctx.user)

    {:ok, view, _} =
      live(Plug.Test.init_test_session(ctx.conn, session_token: token), "/p/#{ctx.project.id}")

    {:ok, generation} = Projects.Store.begin_secret_change(ctx.project.id)

    settings(
      %{ctx | view: view},
      [secrets_pending: true, secrets_generation: generation],
      "machine"
    )

    Repo.delete!(session)
    reject(&Projects.confirm_secret_change/3)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> form("#secret-confirmation-form", confirmed: "true") |> render_submit()

    assert Projects.Store.live_project(ctx.project.id).secrets_pending
  end

  test "saving settings runs off the page, and the page still answers until Fountain does",
       ctx do
    settings(ctx)
    parent = self()

    stub(Projects, :update_settings, fn _, _, attrs ->
      send(parent, {:saving, self()})
      assert attrs["name"] == "Renamed"

      receive do
        :finish -> :ok
      after
        2_000 -> flunk("the save was never released")
      end
    end)

    ctx.view |> form("#settings-form", settings: [name: "Renamed"]) |> render_submit()

    assert_receive {:saving, saving}, 1000
    # A second Save while the first is out starts nothing.
    ctx.view |> form("#settings-form", settings: [name: "Again"]) |> render_submit()
    assert render_patch(ctx.view, "/p/#{ctx.project.id}/settings/general") =~ "settings-form"

    send(saving, :finish)
    render_async(ctx.view, 1000)
    assert render(ctx.view) =~ "Settings saved"
  end

  @tag capture_log: true
  test "a save that crashes re-enables its button and says so", ctx do
    settings(ctx)
    stub(Projects, :update_settings, fn _, _, _ -> raise "Fountain fell over" end)

    ctx.view |> form("#settings-form", settings: [name: "Renamed"]) |> render_submit()

    render_async(ctx.view, 1000)
    assert render(ctx.view) =~ "The operation could not finish"
    # What was typed is still there to try again with.
    assert has_element?(ctx.view, "#settings-name[value=Renamed]")
  end

  test "agent switch counts only this project's open tracks and Cancel makes no write", ctx do
    insert_track(project: ctx.project)
    insert_track(project: ctx.project)
    closed = insert_track(project: ctx.project)
    closed |> Ecto.Changeset.change(closed_at: DateTime.utc_now()) |> Repo.update!()
    insert_track()
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    settings(ctx, [], "agent")
    parent = self()

    expect(Projects, :update_settings, fn caller, id, attrs ->
      assert caller.id == ctx.user.id
      assert id == ctx.project.id
      assert attrs["runtime"] == "codex"
      assert attrs["rebuild"] == true
      send(parent, :switched)
      {:error, {:conflict, "agent_not_connected", "Connect first."}}
    end)

    for _ <- 1..2 do
      ctx.view |> form("#agent-settings-form") |> render_submit(%{settings: %{runtime: "codex"}})
      render_async(ctx.view, 1000)
      assert has_element?(ctx.view, "#agent-switch-confirmation", "This closes 2 open tracks")
      refute_receive :switched, 0
      ctx.view |> element("#agent-switch-confirmation button", "Cancel") |> render_click()
      refute has_element?(ctx.view, "#agent-switch-confirmation")
      assert has_element?(ctx.view, "#settings-runtime[value=codex]")
    end

    ctx.view |> form("#agent-settings-form") |> render_submit(%{settings: %{runtime: "codex"}})
    render_async(ctx.view, 1000)
    ctx.view |> element("#confirm-agent-switch") |> render_click()
    render_async(ctx.view, 1000)
    assert_receive :switched
  end

  test "a revoked session cannot confirm an agent switch", ctx do
    {token, session} = insert_session(ctx.user)
    conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
    {:ok, view, _} = live(conn, "/p/#{ctx.project.id}")
    settings(%{ctx | view: view}, [], "agent")
    reject(&Projects.update_settings/3)
    view |> form("#agent-settings-form") |> render_submit(%{settings: %{runtime: "codex"}})
    render_async(view)
    assert has_element?(view, "#agent-switch-confirmation", "This closes 0 open tracks")
    Repo.delete!(session)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> element("#confirm-agent-switch") |> render_click()
  end

  test "an owner without Codex gets a Harness field error without a provider mutation", ctx do
    catalog = %Catalog{runtimes: ["claude", "codex"], models: %{"codex" => ["openai/test-model"]}}
    settings(ctx, [catalog: catalog], "agent")
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    expect(Ravix.Fountain, :catalog, fn _ -> {:ok, catalog} end)
    reject(&Ravix.Fountain.update_agent/3)
    reject(&Ravix.Fountain.delete_agent/2)

    ctx.view
    |> form("#agent-settings-form")
    |> render_submit(%{
      settings: %{runtime: "codex", model: "openai/test-model", rebuild: "true"}
    })

    render_async(ctx.view, 1000)
    ctx.view |> element("#confirm-agent-switch") |> render_click()
    render_async(ctx.view, 1000)
    assert has_element?(ctx.view, "#settings-runtime ~ p.error", "Connect this agent")
    assert Repo.get!(Ravix.Projects.Project, ctx.project.id).runtime == ctx.project.runtime
  end

  test "an unavailable harness is refused on the box it is about", ctx do
    settings(ctx, [], "agent")

    # `validate_harness/3` answers two codes now, because they are about two
    # inputs: a runtime the catalog does not offer makes every model wrong
    # and is the one to report; past that the harness is fine and the model
    # is not. One code over a two-input form said something true that
    # pointed nowhere.
    for {reason, code, message, id} <- [
          {:unprocessable, "invalid_runtime", "Choose an agent this deployment offers.",
           "#settings-runtime"},
          {:unprocessable, "invalid_model", "Choose one of this agent's models.",
           "#settings-model"},
          {:conflict, "agent_not_connected", "Connect this agent first.", "#settings-runtime"},
          {:unprocessable, "rebuild_required", "Choose Switch and rebuild.", "#settings-runtime"}
        ] do
      expect(Projects, :update_settings, fn _, _, _ ->
        {:error, {reason, code, message}}
      end)

      ctx.view
      |> form("#agent-settings-form")
      |> render_submit(%{settings: %{runtime: "made-up", model: "also-made-up"}})

      render_async(ctx.view, 1000)
      ctx.view |> element("#confirm-agent-switch") |> render_click()
      render_async(ctx.view, 1000)
      assert has_element?(ctx.view, "#agent-settings-form .field p.error", message)

      assert has_element?(ctx.view, "#{id}[value='made-up']") or
               has_element?(ctx.view, "#{id} option[value='also-made-up'][selected]")
    end
  end

  test "a bad secret name is refused, the name kept, and the value never comes back", ctx do
    settings(ctx, [], "machine")

    # `Ravix.Projects.Settings.validate_key/1` is the authority and has its
    # own coverage in `projects_test.exs`; it is stubbed here because this
    # fixture has no Fountain, so a real call refuses for that instead. What
    # is under test is the page: a refusal whose code names a field arrives
    # beside that field rather than as a toast.
    expect(Projects, :update_settings, fn _, _, _ ->
      {:error, {:unprocessable, "bad_key", "A secret name is letters, digits and underscores."}}
    end)

    reject(&Projects.rebuild/2)
    add_secret(ctx.view)

    save_machine(ctx.view,
      secrets: %{"1" => %{store: "env", key: "not a key", value: "private-value"}}
    )

    assert render(ctx.view) =~ "letters, digits and underscores"

    # The key is kept so it can be corrected. The value is not: it is
    # write-only, and rendering it back into the page is the one thing this
    # form must never do, refusal or no refusal.
    assert has_element?(ctx.view, "#secret-key-1[value='not a key']")
    refute render(ctx.view) =~ "private-value"
  end

  test "run scripts can be saved and cleared, and need no rebuild", ctx do
    settings(ctx, [], "machine")
    # A run script alone is not what a machine is built from.
    reject(&Projects.rebuild/2)
    reject(&Projects.update_settings/3)

    # Exercise actual scoped persistence and config validation.
    ctx.view
    |> form("#machine-form",
      preview_defaults: [
        directory: ".",
        command: "PORT=$PORT mix phx.server",
        readiness_path: "",
        stop_command: "mix stop_worker"
      ]
    )
    |> render_submit()

    render_async(ctx.view, 1000)
    assert has_element?(ctx.view, "#machine-review", "Save these changes?")
    assert has_element?(ctx.view, "#machine-review li", "run script edited")
    assert has_element?(ctx.view, "#confirm-machine", "Save")
    refute has_element?(ctx.view, "#machine-review-closing")

    ctx.view |> form("#machine-form") |> put_submitter("#confirm-machine") |> render_submit()
    render_async(ctx.view, 1000)

    assert {:ok, %{readiness_path: nil, stop_command: "mix stop_worker"}} =
             Previews.defaults(ctx.user, ctx.project.id)

    save_machine(ctx.view, preview_defaults: [command: ""])
    assert Previews.defaults(ctx.user, ctx.project.id) == {:ok, nil}
    assert render(ctx.view) =~ "Machine settings saved."
  end

  test "a refused run script lands on its field and nothing after it runs", ctx do
    settings(ctx, [], "machine")
    reject(&Projects.rebuild/2)
    save_machine(ctx.view, preview_defaults: [directory: "../outside", command: "run"])
    assert has_element?(ctx.view, "#machine-form .field p.error")
    assert render(ctx.view) =~ "Could not save the run script"
    assert Previews.defaults(ctx.user, ctx.project.id) == {:ok, nil}
  end

  for action <- ~w(rebuild delete) do
    @action action
    test "#{action} requires the typed project name", ctx do
      settings(ctx, [], "danger")

      expect(Projects, if(@action == "rebuild", do: :rebuild, else: :destroy), fn user, id ->
        assert {user.id, id} == {ctx.user.id, ctx.project.id}
        # The real answers: `rebuild/2` reports what it removed, `destroy/2`
        # has nothing to report.
        if @action == "rebuild",
          do: {:ok, %Rebuild{removed: ["track", "agent"], failed: []}},
          else: :ok
      end)

      ctx.view
      |> form("#project-#{@action}-form", confirm: "wrong")
      |> render_submit(%{action: @action})

      assert render(ctx.view) =~ "Type the project name to confirm"

      ctx.view
      |> form("#project-#{@action}-form", confirm: ctx.project.name)
      |> render_submit(%{action: @action})

      render_async(ctx.view, 1000)
      assert_patch(ctx.view, "/")
    end
  end

  test "a refusal about a field lands on the field; one about the machine stays a toast", ctx do
    render_click(ctx.view, "dialog", %{name: "new-project"})

    # `Ravix.Projects.create/2` decides both of these, and it is still the
    # one that decides them. What the page now does is read the code in
    # `{:unprocessable, code, message}` --- which named a field all along
    # and was thrown away on the way to `RavixWeb.Error` --- and put the
    # context's own sentence beside the input it is about.
    expect(Projects, :create, fn _, _ ->
      {:error, {:unprocessable, "no_name", "Give the project a name."}}
    end)

    ctx.view |> form("#new-project-form", new_project: [name: ""]) |> render_submit()
    render_async(ctx.view, 1000)

    assert has_element?(
             ctx.view,
             "#new-project-form .field p.error",
             "Give the project a name."
           )

    assert has_element?(ctx.view, "#new-project-dialog")

    # A refusal that belongs to no field has no input to sit beside, so it
    # is still a toast. That is the boundary `Form.refuse/2` draws.
    expect(Projects, :create, fn _, _ -> {:error, {:unconfigured, :fountain}} end)

    ctx.view |> form("#new-project-form", new_project: [name: "Fine"]) |> render_submit()
    assert render_async(ctx.view, 1000) =~ RavixWeb.Error.from({:unconfigured, :fountain}).message
    refute has_element?(ctx.view, "#new-project-form .field p.error")
  end

  test "an unconnected runtime is refused on the Agent field", ctx do
    expect(Projects, :create, fn _, attrs ->
      assert attrs["runtime"] == "codex"

      {:error,
       {:conflict, "agent_not_connected", "Connect Codex before creating a project with it."}}
    end)

    render_click(ctx.view, "dialog", %{name: "new-project"})

    render_click(ctx.view, "choose-project-agent", %{"agent" => "codex"})

    ctx.view
    |> form("#new-project-form", new_project: [name: "Keep this", runtime: "codex"])
    |> render_submit()

    render_async(ctx.view, 1000)

    assert has_element?(
             ctx.view,
             "#project-runtime p.error",
             "Connect Codex before creating a project with it."
           )

    assert has_element?(ctx.view, "#project-agent-codex[aria-pressed=true]")
    assert has_element?(ctx.view, "input[name='new_project[name]'][value='Keep this']")
    refute has_element?(ctx.view, "#new-project-form button[disabled]")
  end

  @tag capture_log: true
  test "a crashed provisioning task restores a usable form", ctx do
    expect(Projects, :create, fn _, _ -> raise "provider crashed" end)
    render_click(ctx.view, "dialog", %{name: "new-project"})
    ctx.view |> form("#new-project-form", new_project: [name: "Keep my work"]) |> render_submit()
    assert render_async(ctx.view, 1000) =~ "The operation could not finish"
    refute has_element?(ctx.view, "#new-project-form button[disabled]")
    assert has_element?(ctx.view, "input[name='new_project[name]'][value='Keep my work']")
  end

  test "project invite links persist and revoke through the context", ctx do
    render_click(ctx.view, "dialog", %{name: "people"})
    ctx.view |> element("button", "Create invite link") |> render_click()
    assert has_element?(ctx.view, "#people-dialog a[href*='/j/']")
    ctx.view |> element("button", "Revoke invite link") |> render_click()
    refute has_element?(ctx.view, "#people-dialog a[href*='/j/']")
  end

  test "removing a project member changes database access", ctx do
    member = insert_user()
    People.Store.add_project_member(ctx.project.id, member.id, ctx.user.id)
    render_click(ctx.view, "dialog", %{name: "people"})

    ctx.view
    |> element("button[phx-click=remove-person][phx-value-login='#{member.login}']")
    |> render_click()

    render_async(ctx.view, 1000)
    assert {:error, :not_found} = Projects.get(member, ctx.project.id)
    assert_patch(ctx.view, "/")
  end

  test "inbox attention, search, refresh, and dismiss follow current tracks", ctx do
    # These rows are visible through real scoped context reads.
    track = insert_track(project: ctx.project, title: "Searchable work", error: "Needs help")
    render_click(ctx.view, "refresh")
    # The refresh re-reads the rail in a task now, and the search reads the
    # rail, so it has to have landed first.
    render_async(ctx.view, 1000)
    render_click(ctx.view, "dialog", %{name: "search"})
    render_change(ctx.view, "search", %{q: "SEARCHABLE"})
    assert has_element?(ctx.view, "a[href='/p/#{ctx.project.id}/t/#{track.id}']")
    render_change(ctx.view, "search", %{q: "does-not-exist"})
    refute has_element?(ctx.view, "#search-dialog a[href='/p/#{ctx.project.id}/t/#{track.id}']")

    assert has_element?(
             ctx.view,
             "#search-dialog [role=status]",
             "No tracks match 'does-not-exist'"
           )

    refute has_element?(ctx.view, "#search-dialog h3")
    render_change(ctx.view, "search", %{q: "SEARCHABLE"})
    refute has_element?(ctx.view, "#search-dialog [role=status]")
    assert has_element?(ctx.view, "#search-dialog h3", ctx.project.name)
    assert has_element?(ctx.view, "#search-dialog a", track.title)
    render_click(ctx.view, "dismiss")
    refute has_element?(ctx.view, "#search-dialog")
    send(ctx.view.pid, {:hub, Event.new(:here, ctx.project.id, track_id: track.id)})
    assert render(ctx.view) =~ ctx.project.name
  end

  test "the dialog's own busy flag disables its two irreversible buttons", ctx do
    settings(ctx, [], "danger")
    parent = self()

    # `busy` used to be one boolean for the whole page, written by three
    # unrelated operations --- creating a project, creating a track, and
    # these two --- so what it meant depended on which had touched it last.
    # It belongs to the dialog that renders the buttons it disables.
    stub(Projects, :rebuild, fn _, _ ->
      send(parent, {:rebuilding, self()})

      receive do
        :finish -> {:ok, %Rebuild{removed: ["agent"], failed: []}}
      after
        2_000 -> flunk("rebuild was never released")
      end
    end)

    ctx.view
    |> form("#project-rebuild-form", confirm: ctx.project.name)
    |> render_submit(%{action: "rebuild"})

    assert_receive {:rebuilding, rebuilding}, 1000
    assert has_element?(ctx.view, "button[value=rebuild][disabled]")
    assert has_element?(ctx.view, "button[value=delete][disabled]")

    send(rebuilding, :finish)
    render_async(ctx.view, 1000)
    assert_patch(ctx.view, "/")
  end

  test "a rebuild reports what it could not stop, rather than throwing the report away", ctx do
    settings(ctx, [], "danger")

    # Retiring the agent is the removal that has to work, and it did, so this
    # is `{:ok, _}`. Terminating the live conversations first is best-effort,
    # and a track that would not stop was reported to nobody: `handle_async/3`
    # matched the response and discarded its value.
    stub(Projects, :rebuild, fn _, _ ->
      {:ok,
       %Rebuild{
         removed: ["agent"],
         failed: [
           %Rebuild.Failure{what: "track c-1", why: "Fountain said 503."},
           %Rebuild.Failure{what: "track c-2", why: "Fountain said 503."}
         ]
       }}
    end)

    ctx.view
    |> form("#project-rebuild-form", confirm: ctx.project.name)
    |> render_submit(%{action: "rebuild"})

    render_async(ctx.view, 1000)
    assert_patch(ctx.view, "/")

    html = render(ctx.view)
    assert html =~ "The machine was rebuilt. 2 tracks would not stop first: Fountain said 503."
    # The rebuild happened, so the page does not say it did not.
    refute html =~ "could not finish"
  end

  # RAV-103: what `settings/2` waits for. The read is held open here where
  # the flake only caught it by chance; opening settings under it would
  # cancel it, and a cancelled read that holds the test's connection ends it.
  test "opening settings waits for the project page's agent-health read", ctx do
    parent = self()

    stub(Projects, :agent_health, fn _, _ ->
      send(parent, {:reading_health, self()})
      receive do: (:release -> {:error, :not_found})
    end)

    {:ok, view, _} = live(log_in_user(build_conn(), ctx.user), "/p/#{ctx.project.id}")
    assert_receive {:reading_health, reader}, 1_000
    ref = Process.monitor(reader)
    opening = Task.async(fn -> settings(%{ctx | view: view}) end)

    assert Task.yield(opening, 200) == nil
    send(reader, :release)
    Task.await(opening)
    assert_receive {:DOWN, ^ref, :process, ^reader, :normal}
  end

  test "a rebuild that stopped everything says nothing extra", ctx do
    settings(ctx, [], "danger")
    stub(Projects, :rebuild, fn _, _ -> {:ok, %Rebuild{removed: ["agent"], failed: []}} end)

    ctx.view
    |> form("#project-rebuild-form", confirm: ctx.project.name)
    |> render_submit(%{action: "rebuild"})

    render_async(ctx.view, 1000)
    assert_patch(ctx.view, "/")
    refute render(ctx.view) =~ "would not stop first"
  end

  test "a rebuild that crashes re-enables the buttons and says so", ctx do
    settings(ctx, [], "danger")
    stub(Projects, :rebuild, fn _, _ -> raise "provisioning fell over" end)
    ctx.view |> form("#project-rebuild-form", confirm: ctx.project.name) |> render_change()

    ExUnit.CaptureLog.capture_log(fn ->
      ctx.view
      |> form("#project-rebuild-form", confirm: ctx.project.name)
      |> render_submit(%{action: "rebuild"})

      render_async(ctx.view, 1000)
    end)

    assert render(ctx.view) =~ "The operation could not finish"
    refute has_element?(ctx.view, "button[value=rebuild][disabled]")
  end

  for {section, form_id, params, expected} <- [
        {"general", "settings-form", %{name: "Only a name"}, %{"name" => "Only a name"}},
        {"agent", "agent-settings-form",
         %{runtime: "claude", model: "model", instructions: "Be clear"},
         %{"runtime" => "claude", "model" => "model", "instructions" => "Be clear"}}
      ] do
    @section section
    @form_id form_id
    @params params
    @expected expected
    test "#{form_id} saves only its own fields and reports success", ctx do
      settings(ctx, [], @section)

      expect(Projects, :update_settings, fn _, _, attrs ->
        assert attrs == @expected
        :ok
      end)

      ctx.view |> form("##{@form_id}", settings: @params) |> render_submit()
      assert settled(ctx.view) =~ "Settings saved."
    end

    test "#{form_id} retains inputs on provider failure", ctx do
      settings(ctx, [], @section)
      expect(Projects, :update_settings, fn _, _, _ -> {:error, {:unavailable, "Try later"}} end)
      ctx.view |> form("##{@form_id}", settings: @params) |> render_submit()
      assert settled(ctx.view) =~ "Try later"
      refute render(ctx.view) =~ "Settings saved."
    end
  end

  test "the machine saves only what changed, then rebuilds, after saying so", ctx do
    insert_track(project: ctx.project)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

    settings(
      ctx,
      [packages: %{"apt" => ["curl"]}, env_vars: %{"KEEP" => "1", "OLD" => "x"}],
      "machine"
    )

    # Each is expected once, below, after the Cancel: a write before then
    # would use it up.

    ctx.view
    |> form("#machine-form",
      settings: [setup_script: "npm ci", apt: "curl jq"],
      env_vars: %{"0" => %{key: "KEEP", value: "1"}, "1" => %{key: "OLD", value: "y"}}
    )
    |> render_submit()

    render_async(ctx.view, 1000)
    assert has_element?(ctx.view, "#machine-review", "Save and rebuild the machine?")

    for line <- ["+jq in apt", "setup script edited", "1 variable changed"],
        do: assert(has_element?(ctx.view, "#machine-review li", line))

    assert has_element?(ctx.view, "#machine-review-closing", "Rebuild closes 1 open track")
    # Cancel writes nothing and keeps what was typed.
    ctx.view |> element("#machine-review button", "Cancel") |> render_click()
    refute has_element?(ctx.view, "#machine-review")
    assert has_element?(ctx.view, "#packages-apt[value='curl jq']")

    parent = self()

    expect(Projects, :update_settings, fn user, id, attrs ->
      assert {user.id, id} == {ctx.user.id, ctx.project.id}

      assert attrs == %{
               "setup_script" => "npm ci",
               "packages" => %{"apt" => ["curl", "jq"], "pip" => [], "npm" => []},
               "env_vars" => %{"KEEP" => "1", "OLD" => "y"},
               "expected_env_vars" => %{"KEEP" => "1", "OLD" => "x"}
             }

      send(parent, :saved)
      {:ok, %{rev: 2}}
    end)

    expect(Projects, :rebuild, fn _, _ ->
      send(parent, :rebuilt)
      {:ok, %Rebuild{removed: ["agent"], failed: []}}
    end)

    ctx.view |> element("#machine-form") |> render_submit()
    render_async(ctx.view, 1000)
    ctx.view |> form("#machine-form") |> put_submitter("#confirm-machine") |> render_submit()
    render_async(ctx.view, 1000)
    assert render(ctx.view) =~ "Machine settings saved. The machine is being rebuilt."
    refute has_element?(ctx.view, "#machine-review")
    # Everything is saved before the machine it builds is rebuilt.
    assert_received first when first in [:saved, :rebuilt]
    assert first == :saved
    assert_received :rebuilt
  end

  test "a machine save that fails part-way says what went in and does not rebuild", ctx do
    settings(ctx, [], "machine")
    reject(&Projects.rebuild/2)

    expect(Projects, :update_settings, 2, fn
      _, _, %{"setup_script" => "make"} -> {:ok, %{rev: 2}}
      _, _, %{"secret" => _} -> {:error, {:unavailable, "Try later"}}
    end)

    add_secret(ctx.view)

    save_machine(ctx.view,
      settings: [setup_script: "make"],
      secrets: %{"1" => %{store: "env", key: "API", value: "v"}}
    )

    html = render(ctx.view)
    assert html =~ "Saved the setup, packages and variables. Could not save secret API: Try later"
    # The secret stays to be tried again; its value was never drawn.
    assert has_element?(ctx.view, "#secret-key-1[value=API]")
    refute html =~ ~s(value="v")
  end

  test "a rebuild the machine refuses after a save says the save went in", ctx do
    settings(ctx, [], "machine")
    expect(Projects, :update_settings, fn _, _, _ -> {:ok, %{rev: 2}} end)

    expect(Projects, :rebuild, fn _, _ ->
      {:error, {:conflict, "dedicated_lifecycle_pending", "Not available yet."}}
    end)

    save_machine(ctx.view, settings: [setup_script: "make"])

    assert render(ctx.view) =~
             "Saved the setup, packages and variables. The machine was not rebuilt: Not available yet."
  end

  test "a machine whose tracks all have their own saves without a rebuild", ctx do
    settings(ctx, [default_only: true, shared_tracks: 0], "machine")
    assert has_element?(ctx.view, "#project-machine-bar button[data-unsaved-save]", "Save")
    refute has_element?(ctx.view, "#project-machine-bar", "rebuild")
    reject(&Projects.rebuild/2)
    expect(Projects, :update_settings, fn _, _, _ -> {:ok, %{rev: 2}} end)
    ctx.view |> form("#machine-form", settings: [setup_script: "make"]) |> render_submit()
    render_async(ctx.view, 1000)
    assert has_element?(ctx.view, "#machine-review", "No project machine to rebuild")
    ctx.view |> form("#machine-form") |> put_submitter("#confirm-machine") |> render_submit()
    assert render_async(ctx.view, 1000) =~ "Machine settings saved."
  end

  test "nothing changed is nothing to save, and a bad list is refused before any write", ctx do
    settings(ctx, [], "machine")
    reject(&Projects.update_settings/3)
    reject(&Projects.rebuild/2)
    ctx.view |> form("#machine-form") |> render_submit()
    assert render(ctx.view) =~ "Nothing to save"
    refute has_element?(ctx.view, "#machine-review")

    ctx.view |> element("button", "Add variable") |> render_click()
    ctx.view |> form("#machine-form") |> render_submit()
    assert render(ctx.view) =~ "Use a name of at most 200 bytes"

    add_secret(ctx.view)

    ctx.view
    |> form("#machine-form",
      secrets: %{"1" => %{key: "NO_VALUE"}},
      env_vars: %{"0" => %{key: "A", value: ""}}
    )
    |> render_submit()

    assert render(ctx.view) =~ "Enter a value for each secret you set."
    refute has_element?(ctx.view, "#machine-review")
  end

  test "a confirmed save whose form no longer matches the summary is asked again", ctx do
    settings(ctx, [], "machine")
    reject(&Projects.update_settings/3)
    reject(&Projects.rebuild/2)
    ctx.view |> form("#machine-form", settings: [setup_script: "one"]) |> render_submit()
    render_async(ctx.view, 1000)
    assert has_element?(ctx.view, "#machine-review li", "setup script edited")

    # A forged confirmation with more in it than the owner was shown.
    render_submit(ctx.view |> element("#machine-form"), %{
      "settings" => %{"setup_script" => "one", "apt" => "sl"},
      "machine_confirm" => "true"
    })

    render_async(ctx.view, 1000)
    assert has_element?(ctx.view, "#machine-review li", "+sl in apt")
  end

  test "destructive actions have independent confirmations that disable again when edited", ctx do
    settings(ctx, [], "danger")

    for action <- ~w(rebuild delete) do
      assert has_element?(ctx.view, "#project-#{action}-form button[disabled]")
      ctx.view |> form("#project-#{action}-form", confirm: ctx.project.name) |> render_change()
      assert has_element?(ctx.view, "#project-#{action}-form button:not([disabled])")
      other = if action == "rebuild", do: "delete", else: "rebuild"
      assert has_element?(ctx.view, "#project-#{other}-form button[disabled]")

      ctx.view
      |> form("#project-#{action}-form", confirm: "#{ctx.project.name} ")
      |> render_change()

      assert has_element?(ctx.view, "#project-#{action}-form button[disabled]")
    end
  end

  test "settings offers the same agent products as creation and retains a saved legacy agent",
       ctx do
    catalog = %{Catalog.empty() | runtimes: ~w(claude codex gemini opencode acp)}
    settings(ctx, [catalog: catalog, runtime: "gemini"], "agent")
    assert has_element?(ctx.view, "#settings-agent-claude", "Claude Code")
    assert has_element?(ctx.view, "#settings-agent-codex", "Codex")
    assert has_element?(ctx.view, "#settings-runtime[value=gemini]")
    assert has_element?(ctx.view, "#settings-section-agent", "Current agent: Gemini CLI")
    refute has_element?(ctx.view, "#settings-agent-opencode")
    refute has_element?(ctx.view, "#settings-agent-acp")
  end

  test "all-dedicated agent settings explain defaults and hide project rebuild", ctx do
    settings(ctx, [default_only: true, shared_tracks: 0], "agent")

    assert has_element?(
             ctx.view,
             "#settings-section-agent",
             "Changes the default agent for new threads. Existing threads keep their agent."
           )

    refute has_element?(ctx.view, "#settings-section-agent", "Switching agents rebuilds")
    render_patch(ctx.view, "/p/#{ctx.project.id}/settings/danger")
    refute has_element?(ctx.view, "#project-rebuild-form")
  end

  test "mixed settings name the shared tracks before destructive switching", ctx do
    settings(ctx, [default_only: false, shared_tracks: 2], "agent")

    assert has_element?(
             ctx.view,
             "#settings-section-agent",
             "2 tracks still share the project machine"
           )

    render_patch(ctx.view, "/p/#{ctx.project.id}/settings/danger")
    assert has_element?(ctx.view, "#project-rebuild-form")
  end

  test "one shared track uses singular wording", ctx do
    settings(ctx, [default_only: false, shared_tracks: 1], "agent")

    assert has_element?(
             ctx.view,
             "#settings-section-agent",
             "1 track still shares the project machine"
           )

    assert has_element?(ctx.view, "#settings-section-agent", "Switching agents rebuilds")
  end

  test "danger actions require the exact project name", ctx do
    settings(ctx, [], "danger")
    assert has_element?(ctx.view, "#delete-confirm[required]")
    reject(&Projects.destroy/2)

    ctx.view
    |> form("#project-delete-form", confirm: "wrong")
    |> render_submit(%{action: "delete"})

    assert render(ctx.view) =~ "Type the project name to confirm"
  end

  test "secret removal sends an empty value without retaining a value", ctx do
    settings(ctx, [env_keys: ["TOKEN"]], "machine")

    expect(Projects, :update_settings, fn _, _, %{"secret" => secret} ->
      assert secret == %{"store" => "env", "key" => "TOKEN", "value" => ""}
      {:ok, %{rev: 2}}
    end)

    expect(Projects, :rebuild, fn _, _ -> {:ok, %Rebuild{removed: [], failed: []}} end)

    ctx.view
    |> element(~s(button[aria-label="Remove Environment secret TOKEN"]))
    |> render_click()

    assert has_element?(ctx.view, "#secret-key-env-TOKEN", "Removed on save")
    ctx.view |> form("#machine-form") |> render_submit()
    render_async(ctx.view, 1000)
    assert has_element?(ctx.view, "#machine-review li", "1 secret removed")
    ctx.view |> form("#machine-form") |> put_submitter("#confirm-machine") |> render_submit()
    assert render_async(ctx.view, 1000) =~ "Machine settings saved"
  end

  test "only a held key can be replaced or removed, and only once a save", ctx do
    settings(ctx, [env_keys: ["TOKEN"], vault_keys: ["SHARED"]], "machine")
    remove_vault = ~s(button[aria-label="Remove Vault secret SHARED"])

    # Forged events, on a button there is: a key in the other store, a key
    # nobody holds, a store there is not, an action there is not.
    for forged <- [
          %{store: "vault", key: "TOKEN", action: "remove"},
          %{store: "env", key: "OTHER", action: "remove"},
          %{store: "elsewhere", key: "TOKEN", action: "remove"},
          %{store: "env", key: "TOKEN", action: "rename"}
        ] do
      ctx.view |> element(remove_vault) |> render_click(forged)
    end

    refute has_element?(ctx.view, ".secret-row")

    ctx.view
    |> element(~s(button[aria-label="Replace Environment secret TOKEN"]))
    |> render_click()

    assert has_element?(ctx.view, "label[for=secret-value-1]", "New value for TOKEN")
    # The key has its row: its buttons are gone, and a second row for it is
    # refused even when asked for.
    refute has_element?(ctx.view, ~s(button[aria-label="Remove Environment secret TOKEN"]))

    ctx.view
    |> element(remove_vault)
    |> render_click(%{store: "env", key: "TOKEN", action: "remove"})

    refute has_element?(ctx.view, "#secret-row-2")
    ctx.view |> element("#secret-row-1 button", "Undo") |> render_click()
    refute has_element?(ctx.view, ".secret-row")
  end

  test "a delayed settings save rechecks the session before returning data", ctx do
    {token, session} = insert_session(ctx.user)

    {:ok, view, _} =
      live(Plug.Test.init_test_session(ctx.conn, session_token: token), "/p/#{ctx.project.id}")

    settings(%{ctx | view: view})
    parent = self()

    expect(Projects, :update_settings, fn _, _, _ ->
      send(parent, {:saving_settings, self()})

      receive do
        :finish -> :ok
      after
        2_000 -> flunk("save was not released")
      end
    end)

    view |> form("#settings-form", settings: [name: "Delayed"]) |> render_submit()
    assert_receive {:saving_settings, task}, 1000
    Repo.delete!(session)
    send(task, :finish)
    assert_redirect(view, "/login")
  end

  test "stored secrets are listed by key name only, with a way to replace or remove each",
       ctx do
    settings(ctx, [env_keys: ["API_TOKEN"], vault_keys: ["GITHUB_TOKEN"]], "machine")

    for {store, label, key} <- [
          {"env", "Environment", "API_TOKEN"},
          {"vault", "Vault", "GITHUB_TOKEN"}
        ],
        action <- ["Replace", "Remove"] do
      assert has_element?(ctx.view, "#secret-key-#{store}-#{key}", key)

      assert has_element?(
               ctx.view,
               ~s(#secret-key-#{store}-#{key} button[aria-label="#{action} #{label} secret #{key}"]),
               action
             )
    end

    ctx.view
    |> element(~s(button[aria-label="Replace Vault secret GITHUB_TOKEN"]))
    |> render_click()

    assert has_element?(ctx.view, "#secret-key-vault-GITHUB_TOKEN", "Replaced on save")
    assert has_element?(ctx.view, "#secret-value-1[type=password]")
    refute has_element?(ctx.view, "#secret-value-1[value]")
  end

  test "a settings event after the owner lost the project is refused before any write", ctx do
    settings(ctx, [], "machine")
    # Settle the initial rail before removing access: otherwise that earlier read
    # can dismiss the page before the test submits the event it is exercising.
    render_async(ctx.view, 1_000)
    add_secret(ctx.view)
    reject(&Projects.update_settings/3)
    reject(&Projects.rebuild/2)

    ctx.project
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()

    ctx.view
    |> form("#machine-form",
      secrets: %{"1" => %{store: "env", key: "TOKEN", value: "never-sent"}}
    )
    |> render_submit()

    html = render(ctx.view)
    assert html =~ "No such thing here."
    refute html =~ "never-sent"
    refute html =~ "Machine settings saved"
  end

  test "a second section's save is not started while the first is still out", ctx do
    settings(ctx)
    parent = self()

    expect(Projects, :update_settings, 1, fn _, _, attrs ->
      send(parent, {:saving, self()})
      assert attrs == %{"name" => "First"}

      receive do
        :finish -> :ok
      after
        2_000 -> flunk("the save was never released")
      end
    end)

    ctx.view |> form("#settings-form", settings: [name: "First"]) |> render_submit()
    assert_receive {:saving, saving}, 1000
    render_patch(ctx.view, "/p/#{ctx.project.id}/settings/agent")

    ctx.view
    |> form("#agent-settings-form", settings: [instructions: "Second"])
    |> render_submit()

    # The second form keeps what was typed, so nothing is lost by waiting.
    assert has_element?(ctx.view, "#settings-instructions", "Second")
    send(saving, :finish)
    assert settled(ctx.view) =~ "Settings saved."
  end

  test "preview defaults that cannot be read open on the usual starting values", ctx do
    stub(Previews, :defaults, fn _, _ -> {:error, {:unavailable, "Try later"}} end)
    settings(ctx, [], "machine")

    assert has_element?(ctx.view, "#default-directory[value='.']")
    assert has_element?(ctx.view, "#default-readiness[value='']")
  end

  describe "a session that went without notice" do
    # The page is a `live_component`, and the page's session hooks never
    # see a component's events: without the wrapping in
    # `RavixWeb.Live.Hooks`, a revoked session could keep saving settings
    # and deleting projects until the page happened to receive a message.
    test "cannot save settings through the page", ctx do
      view = revoked(ctx, "general")
      reject(&Projects.update_settings/3)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> form("#settings-form", settings: [name: "Renamed"]) |> render_submit()
    end

    for {section, id} <- [{"agent", "agent-settings-form"}, {"machine", "machine-form"}] do
      @section section
      @id id
      test "revoked session cannot submit #{id}", ctx do
        view = revoked(ctx, @section)
        reject(&Projects.update_settings/3)
        reject(&Previews.set_defaults/3)

        assert {:error, {:redirect, %{to: "/login"}}} =
                 view |> form("##{@id}") |> render_submit()
      end
    end

    test "revoked session cannot confirm a machine save", ctx do
      {token, session} = insert_session(ctx.user)
      conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
      {:ok, view, _} = live(conn, "/p/#{ctx.project.id}")
      settings(%{ctx | view: view}, [], "machine")
      view |> form("#machine-form", settings: [setup_script: "make"]) |> render_submit()
      render_async(view, 1000)
      assert has_element?(view, "#machine-review")
      Repo.delete!(session)
      reject(&Projects.update_settings/3)
      reject(&Projects.rebuild/2)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#machine-form")
               |> put_submitter("#confirm-machine")
               |> render_submit()
    end

    test "revoked session cannot enable a destructive action", ctx do
      view = revoked(ctx, "danger")

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#project-delete-form", confirm: ctx.project.name)
               |> render_change()
    end

    test "revoked session cannot rebuild", ctx do
      view = revoked(ctx, "danger")
      reject(&Projects.rebuild/2)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#project-rebuild-form", confirm: ctx.project.name)
               |> render_submit(%{action: "rebuild"})
    end

    test "cannot add a secret through the page", ctx do
      view = revoked(ctx, "machine")
      reject(&Projects.update_settings/3)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> element("button", "Add secret") |> render_click()
    end

    test "cannot delete the project through the page", ctx do
      view = revoked(ctx, "danger")
      reject(&Projects.destroy/2)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#project-delete-form", confirm: ctx.project.name)
               |> render_submit(%{action: "delete"})

      assert {:ok, _project} = Projects.get(ctx.user, ctx.project.id)
    end
  end

  defp revoked(ctx, section) do
    {token, session} = insert_session(ctx.user)
    conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
    {:ok, view, _} = live(conn, "/p/#{ctx.project.id}")
    settings(%{ctx | view: view}, [], section)
    Repo.delete!(session)
    view
  end

  # A settings save's answer, and the flash it hands the page one message
  # later: `:sys.get_state/1` returns once the page has taken that message.
  defp settled(view) do
    render_async(view, 1000)
    :sys.get_state(view.pid)
    render(view)
  end

  defp add_secret(view), do: view |> element("button", "Add secret") |> render_click()

  # The Machine page's two submits: the one that asks, and the confirmation.
  defp save_machine(view, params) do
    view |> form("#machine-form", params) |> render_submit()
    render_async(view, 1000)

    if has_element?(view, "#machine-review") do
      view
      |> form("#machine-form", params)
      |> put_submitter("#confirm-machine")
      |> render_submit()

      render_async(view, 1000)
    end
  end

  defp settings(ctx, overrides \\ [], section \\ "general") do
    stub(Projects, :settings, fn _, _ ->
      {:ok,
       Enum.into(overrides, %{
         env_vars: %{},
         name: ctx.project.name,
         runtime: "claude",
         model: "model",
         instructions: "",
         setup_script: "",
         packages: %{},
         env_keys: [],
         vault_keys: [],
         catalog: Catalog.empty()
       })}
    end)

    # RAV-103. The project page's own reads have to be over before this patches
    # away from it. The patch removes `RavixWeb.Live.AgentHealth`, and removing
    # a component cancels its tasks; one cancelled while it holds this test's
    # sandbox connection takes the connection down with it, so the next thing
    # the page reads --- the session, on the first settings event --- finds no
    # owner. `live/2` hands the page back with that read still out.
    render_async(ctx.view, 5_000)
    render_patch(ctx.view, "/p/#{ctx.project.id}/settings/#{section}")
    render_async(ctx.view)
  end
end

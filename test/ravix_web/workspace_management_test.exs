defmodule RavixWeb.WorkspaceManagementTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Accounts, People, Previews, Projects, Repo, Tracks}
  alias Ravix.Fountain.Client
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Hub.Event
  alias Ravix.Projects.Machine.Rebuild

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    %{view: view, user: user, project: project}
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
    settings(ctx, catalog: catalog, model: hd(models))
    render_async(ctx.view)

    html = render(ctx.view) |> LazyHTML.from_document()

    [encoded] =
      html |> LazyHTML.query("#settings-sections") |> LazyHTML.attribute("data-model-labels")

    assert Jason.decode!(encoded) == Map.new(labels)

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
        assert composer
               |> LazyHTML.query("[phx-value-model='#{choice}'] .truncate")
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
    render_async(ctx.view)
    ctx.view |> form("#new-project-form", new_project: [name: "Waiting"]) |> render_submit()
    assert_receive {:creating, task}
    assert has_element?(ctx.view, "#new-project-form [role=status]", "Creating project")
    assert has_element?(ctx.view, "#new-project-form button[disabled]", "Creating project")
    send(task, :finish)
    assert render_async(ctx.view) =~ "Machine unavailable"
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
      assert_receive {:loading_repos, task}
      assert has_element?(ctx.view, "#new-project-dialog [role=status]", "Loading GitHub")
      assert has_element?(ctx.view, "#project-repo[disabled]")
      send(task, :finish)
      render_async(ctx.view)
      refute has_element?(ctx.view, "#new-project-dialog .loading-status")
      refute has_element?(ctx.view, "#project-repo[disabled]")
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

    ctx.view
    |> form("#new-project-form",
      new_project: [name: "Selected", repo: "acme/app", runtime: "codex"]
    )
    |> render_change()

    ctx.view
    |> form("#new-project-form",
      new_project: [name: "Selected", repo: "acme/app", runtime: "codex"]
    )
    |> render_submit()

    assert render_async(ctx.view) =~ "Provisioning is offline"
    assert has_element?(ctx.view, "input[name='new_project[name]'][value=Selected]")
    assert has_element?(ctx.view, "#project-runtime option[value=codex][selected]")
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
        assert attrs == %{title: if(@kind == "pr", do: nil, else: "Work"), origin: @expected}
        {:error, {:conflict, "busy", "Machine is busy"}}
      end)

      render_click(ctx.view, "dialog", %{name: "new-track"})
      render_click(ctx.view, "origin", %{kind: @kind})
      # Listing a repository's branches, pulls or issues is a GitHub call,
      # and the form cannot be submitted against a ref that has not arrived.
      render_async(ctx.view)

      params =
        if ref,
          do: %{title: "Work", ref: to_string(ref[:number] || ref[:name])},
          else: %{title: "Work"}

      params = if @kind == "pr", do: Map.delete(params, :title), else: params
      ctx.view |> form("#new-track-form", new_track: params) |> render_submit()
      assert render_async(ctx.view) =~ "Machine is busy"
      refute has_element?(ctx.view, "#new-track-form button[disabled]")
    end
  end

  test "branch validation errors keep the entered name beside the fixed prefix", ctx do
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
      render_async(ctx.view)
      assert has_element?(ctx.view, "#new-track-form .field p.error", message)
      assert has_element?(ctx.view, "#track-title[value='#{name}']")
      refute has_element?(ctx.view, "#new-track-form button[disabled]")
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
    render_async(ctx.view)
    refute has_element?(ctx.view, "#track-title")
    ctx.view |> form("#new-track-form", new_track: [ref: "12"]) |> render_submit()
    render_async(ctx.view)
    assert has_element?(ctx.view, "#new-track-form p.error", "That branch name is already used")
  end

  test "secrets are scoped and values are absent from the rendered page", ctx do
    settings(ctx)

    expect(Projects, :update_settings, fn user, id, attrs ->
      assert {user.id, id} == {ctx.user.id, ctx.project.id}

      assert attrs == %{
               secret: %{"store" => "vault", "key" => "TOKEN", "value" => "private-value"}
             }

      :ok
    end)

    ctx.view
    |> form("#secret-form", secret: [store: "vault", key: "TOKEN", value: "private-value"])
    |> render_submit()

    # The write is a Fountain round trip and runs off the page, and the
    # dialog hands its sentence to the page one message after the answer.
    render_async(ctx.view)
    html = render(ctx.view)
    assert html =~ "Secret updated"
    refute html =~ "private-value"
  end

  test "saving settings runs off the page, with the button disabled until Fountain answers",
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

    assert_receive {:saving, saving}
    assert has_element?(ctx.view, "#settings-form button[disabled]")
    # The secret form is not the one that is out, and the page still answers.
    refute has_element?(ctx.view, "#secret-form button[disabled]")
    assert render_click(ctx.view, "dialog", %{name: "settings"}) =~ "settings-form"

    send(saving, :finish)
    render_async(ctx.view)
    assert render(ctx.view) =~ "Settings saved"
    refute has_element?(ctx.view, "#settings-form button[disabled]")
  end

  @tag capture_log: true
  test "a save that crashes re-enables its button and says so", ctx do
    settings(ctx)
    stub(Projects, :update_settings, fn _, _, _ -> raise "Fountain fell over" end)

    ctx.view |> form("#settings-form", settings: [name: "Renamed"]) |> render_submit()

    render_async(ctx.view)
    assert render(ctx.view) =~ "The operation could not finish"
    refute has_element?(ctx.view, "#settings-form button[disabled]")
    # What was typed is still there to try again with.
    assert has_element?(ctx.view, "#settings-name[value=Renamed]")
  end

  test "an unavailable harness is refused on the box it is about", ctx do
    settings(ctx)

    # `validate_harness/3` answers two codes now, because they are about two
    # inputs: a runtime the catalog does not offer makes every model wrong
    # and is the one to report; past that the harness is fine and the model
    # is not. One code over a two-input form said something true that
    # pointed nowhere.
    for {code, message, id} <- [
          {"invalid_runtime", "Choose an agent this deployment offers.", "#settings-runtime"},
          {"invalid_model", "Choose one of this agent's models.", "#settings-model"}
        ] do
      expect(Projects, :update_settings, fn _, _, _ ->
        {:error, {:unprocessable, code, message}}
      end)

      ctx.view
      |> form("#agent-settings-form")
      |> render_submit(%{settings: %{runtime: "made-up", model: "also-made-up"}})

      render_async(ctx.view)
      assert has_element?(ctx.view, "#agent-settings-form .field p.error", message)

      assert has_element?(ctx.view, "#{id} option[value='made-up'][selected]") or
               has_element?(ctx.view, "#{id} option[value='also-made-up'][selected]")
    end
  end

  test "a bad secret name is refused on the name, and the value never comes back", ctx do
    settings(ctx)

    # `Ravix.Projects.Settings.validate_key/1` is the authority and has its
    # own coverage in `projects_test.exs`; it is stubbed here because this
    # fixture has no Fountain, so a real call refuses for that instead. What
    # is under test is the page: a refusal whose code names a field arrives
    # beside that field rather than as a toast.
    expect(Projects, :update_settings, fn _, _, _ ->
      {:error, {:unprocessable, "bad_key", "A secret name is letters, digits and underscores."}}
    end)

    ctx.view
    |> form("#secret-form", secret: [store: "env", key: "not a key", value: "private-value"])
    |> render_submit()

    render_async(ctx.view)

    assert has_element?(
             ctx.view,
             "#secret-form .field p.error",
             "letters, digits and underscores"
           )

    # The key is kept so it can be corrected. The value is not: it is
    # write-only, and rendering it back into the page is the one thing this
    # form must never do, refusal or no refusal.
    assert has_element?(ctx.view, "#secret-key[value='not a key']")
    refute render(ctx.view) =~ "private-value"
  end

  test "preview defaults can be saved and cleared", ctx do
    settings(ctx)
    # Exercise actual scoped persistence and config validation.
    ctx.view
    |> form("#preview-defaults-form",
      preview_defaults: [
        directory: ".",
        command: "PORT=$PORT mix phx.server",
        readiness_path: "/healthz"
      ]
    )
    |> render_submit()

    assert {:ok, %{readiness_path: "/healthz"}} = Previews.defaults(ctx.user, ctx.project.id)
    ctx.view |> form("#preview-defaults-form") |> render_submit(%{clear: "true"})
    assert Previews.defaults(ctx.user, ctx.project.id) == {:ok, nil}
  end

  for action <- ~w(rebuild delete) do
    @action action
    test "#{action} requires the typed project name", ctx do
      settings(ctx)

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

      render_async(ctx.view)
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
    render_async(ctx.view)

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
    assert render_async(ctx.view) =~ RavixWeb.Error.from({:unconfigured, :fountain}).message
    refute has_element?(ctx.view, "#new-project-form .field p.error")
  end

  @tag capture_log: true
  test "a crashed provisioning task restores a usable form", ctx do
    expect(Projects, :create, fn _, _ -> raise "provider crashed" end)
    render_click(ctx.view, "dialog", %{name: "new-project"})
    ctx.view |> form("#new-project-form", new_project: [name: "Keep my work"]) |> render_submit()
    assert render_async(ctx.view) =~ "The operation could not finish"
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
    ctx.view |> element("button[phx-value-login='#{member.login}']") |> render_click()
    render_async(ctx.view)
    assert {:error, :not_found} = Projects.get(member, ctx.project.id)
    assert_patch(ctx.view, "/")
  end

  test "inbox attention, search, refresh, and dismiss follow current tracks", ctx do
    # These rows are visible through real scoped context reads.
    track = insert_track(project: ctx.project, title: "Searchable work", error: "Needs help")
    render_click(ctx.view, "refresh")
    # The refresh re-reads the rail in a task now, and the search reads the
    # rail, so it has to have landed first.
    render_async(ctx.view)
    render_click(ctx.view, "dialog", %{name: "search"})
    render_change(ctx.view, "search", %{q: "SEARCHABLE"})
    assert has_element?(ctx.view, "a[href='/p/#{ctx.project.id}/t/#{track.id}']")
    render_change(ctx.view, "search", %{q: "does-not-exist"})
    refute has_element?(ctx.view, "#search-dialog a[href='/p/#{ctx.project.id}/t/#{track.id}']")
    render_click(ctx.view, "dismiss")
    refute has_element?(ctx.view, "#search-dialog")
    send(ctx.view.pid, {:hub, Event.new(:here, ctx.project.id, track_id: track.id)})
    assert render(ctx.view) =~ ctx.project.name
  end

  test "the dialog's own busy flag disables its two irreversible buttons", ctx do
    settings(ctx)
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

    assert_receive {:rebuilding, rebuilding}
    assert has_element?(ctx.view, "button[value=rebuild][disabled]")
    assert has_element?(ctx.view, "button[value=delete][disabled]")

    send(rebuilding, :finish)
    render_async(ctx.view)
    assert_patch(ctx.view, "/")
  end

  test "a rebuild reports what it could not stop, rather than throwing the report away", ctx do
    settings(ctx)

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

    render_async(ctx.view)
    assert_patch(ctx.view, "/")

    html = render(ctx.view)
    assert html =~ "The machine was rebuilt. 2 tracks would not stop first: Fountain said 503."
    # The rebuild happened, so the page does not say it did not.
    refute html =~ "could not finish"
  end

  test "a rebuild that stopped everything says nothing extra", ctx do
    settings(ctx)
    stub(Projects, :rebuild, fn _, _ -> {:ok, %Rebuild{removed: ["agent"], failed: []}} end)

    ctx.view
    |> form("#project-rebuild-form", confirm: ctx.project.name)
    |> render_submit(%{action: "rebuild"})

    render_async(ctx.view)
    assert_patch(ctx.view, "/")
    refute render(ctx.view) =~ "would not stop first"
  end

  test "a rebuild that crashes re-enables the buttons and says so", ctx do
    settings(ctx)
    stub(Projects, :rebuild, fn _, _ -> raise "provisioning fell over" end)
    ctx.view |> form("#project-rebuild-form", confirm: ctx.project.name) |> render_change()

    ExUnit.CaptureLog.capture_log(fn ->
      ctx.view
      |> form("#project-rebuild-form", confirm: ctx.project.name)
      |> render_submit(%{action: "rebuild"})

      render_async(ctx.view)
    end)

    assert render(ctx.view) =~ "The operation could not finish"
    refute has_element?(ctx.view, "button[value=rebuild][disabled]")
  end

  for {form_id, params, expected} <- [
        {"settings-form", %{name: "Only a name"}, %{"name" => "Only a name"}},
        {"agent-settings-form", %{runtime: "claude", model: "model", instructions: "Be clear"},
         %{"runtime" => "claude", "model" => "model", "instructions" => "Be clear"}},
        {"environment-settings-form",
         %{setup_script: "npm ci", apt: "git,curl", pip: "", npm: ""},
         %{
           "setup_script" => "npm ci",
           "packages" => %{"apt" => ["git", "curl"], "pip" => [], "npm" => []}
         }}
      ] do
    @form_id form_id
    @params params
    @expected expected
    test "#{form_id} saves only its own fields and reports success", ctx do
      settings(ctx)

      expect(Projects, :update_settings, fn _, _, attrs ->
        assert attrs == @expected
        :ok
      end)

      ctx.view |> form("##{@form_id}", settings: @params) |> render_submit()
      assert render_async(ctx.view) =~ "Saved."
    end

    test "#{form_id} retains inputs on provider failure", ctx do
      settings(ctx)
      expect(Projects, :update_settings, fn _, _, _ -> {:error, {:unavailable, "Try later"}} end)
      ctx.view |> form("##{@form_id}", settings: @params) |> render_submit()
      assert render_async(ctx.view) =~ "Could not save"
      assert render(ctx.view) =~ "Try later"
    end
  end

  test "destructive actions have independent confirmations that disable again when edited", ctx do
    settings(ctx)

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
    settings(ctx, catalog: catalog, runtime: "gemini")
    assert has_element?(ctx.view, "label[for=settings-runtime]", "Agent")
    assert has_element?(ctx.view, "#settings-runtime option[value=claude]", "Claude Code")
    assert has_element?(ctx.view, "#settings-runtime option[value=codex]", "Codex")

    assert has_element?(
             ctx.view,
             "#settings-runtime option[value=gemini][selected]",
             "Gemini CLI"
           )

    refute has_element?(ctx.view, "#settings-runtime option[value=opencode]")
    refute has_element?(ctx.view, "#settings-runtime option[value=acp]")
  end

  test "danger actions require the exact project name", ctx do
    settings(ctx)
    assert has_element?(ctx.view, "#delete-confirm[required]")
    reject(&Projects.destroy/2)

    ctx.view
    |> form("#project-delete-form", confirm: "wrong")
    |> render_submit(%{action: "delete"})

    assert render(ctx.view) =~ "Type the project name to confirm"
  end

  test "secret removal sends an empty value without retaining a value", ctx do
    settings(ctx)

    expect(Projects, :update_settings, fn _, _, %{secret: secret} ->
      assert secret == %{"store" => "env", "key" => "TOKEN", "value" => ""}
      :ok
    end)

    ctx.view
    |> form("#secret-form", secret: [store: "env", key: "TOKEN", value: ""])
    |> render_submit()

    assert render_async(ctx.view) =~ "Secret updated"
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
    assert_receive {:saving_settings, task}
    Repo.delete!(session)
    send(task, :finish)
    assert_redirect(view, "/login")
  end

  test "stored secrets are listed by key name only, with a way to replace or remove each",
       ctx do
    settings(ctx, env_keys: ["API_TOKEN"], vault_keys: ["GITHUB_TOKEN"])

    for {store, label, key} <- [
          {"env", "Environment", "API_TOKEN"},
          {"vault", "Vault", "GITHUB_TOKEN"}
        ],
        action <- ["replace", "remove"] do
      assert has_element?(
               ctx.view,
               ~s(button[data-secret-store="#{store}"][data-secret-key="#{key}"][data-secret-action="#{action}"]),
               String.capitalize(action)
             )

      assert has_element?(
               ctx.view,
               ~s(button[aria-label="#{String.capitalize(action)} #{label} secret #{key}"])
             )
    end

    assert has_element?(ctx.view, "#secret-value[type=password]")
    refute has_element?(ctx.view, "#secret-value[value]")
  end

  test "a settings event after the owner lost the project is refused before any write", ctx do
    settings(ctx)
    reject(&Projects.update_settings/3)

    ctx.project
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()

    ctx.view
    |> form("#secret-form", secret: [store: "env", key: "TOKEN", value: "never-sent"])
    |> render_submit()

    html = render(ctx.view)
    assert html =~ "No such thing here."
    refute html =~ "never-sent"
    refute html =~ "Secret updated"
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
    assert_receive {:saving, saving}

    ctx.view
    |> form("#agent-settings-form", settings: [instructions: "Second"])
    |> render_submit()

    # The second form keeps what was typed, so nothing is lost by waiting.
    assert has_element?(ctx.view, "#settings-instructions", "Second")
    send(saving, :finish)
    assert render_async(ctx.view) =~ "Saved."
  end

  test "preview defaults that cannot be read open on the usual starting values", ctx do
    stub(Previews, :defaults, fn _, _ -> {:error, {:unavailable, "Try later"}} end)
    settings(ctx)

    assert has_element?(ctx.view, "#default-directory[value='.']")
    assert has_element?(ctx.view, "#default-readiness[value='/']")
  end

  describe "a session that went without notice" do
    # The dialog is a `live_component`, and the page's session hooks never
    # see a component's events: without the wrapping in
    # `RavixWeb.Live.Hooks`, a revoked session could keep saving settings
    # and deleting projects until the page happened to receive a message.
    setup ctx do
      {token, session} = insert_session(ctx.user)
      conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
      {:ok, view, _} = live(conn, "/p/#{ctx.project.id}")
      settings(%{ctx | view: view})
      Repo.delete!(session)
      %{view: view}
    end

    test "cannot save settings through the dialog", ctx do
      reject(&Projects.update_settings/3)

      assert {:error, {:redirect, %{to: "/login"}}} =
               ctx.view |> form("#settings-form", settings: [name: "Renamed"]) |> render_submit()
    end

    for id <- ["agent-settings-form", "environment-settings-form", "preview-defaults-form"] do
      @id id
      test "revoked session cannot submit #{id}", ctx do
        reject(&Projects.update_settings/3)

        assert {:error, {:redirect, %{to: "/login"}}} =
                 ctx.view |> form("##{@id}") |> render_submit()
      end
    end

    test "revoked session cannot enable a destructive action", ctx do
      assert {:error, {:redirect, %{to: "/login"}}} =
               ctx.view
               |> form("#project-delete-form", confirm: ctx.project.name)
               |> render_change()
    end

    test "revoked session cannot rebuild", ctx do
      reject(&Projects.rebuild/2)

      assert {:error, {:redirect, %{to: "/login"}}} =
               ctx.view
               |> form("#project-rebuild-form", confirm: ctx.project.name)
               |> render_submit(%{action: "rebuild"})
    end

    test "cannot save a secret through the dialog", ctx do
      reject(&Projects.update_settings/3)

      assert {:error, {:redirect, %{to: "/login"}}} =
               ctx.view
               |> form("#secret-form", secret: [store: "env", key: "TOKEN", value: "v"])
               |> render_submit()
    end

    test "cannot delete the project through the dialog", ctx do
      reject(&Projects.destroy/2)

      assert {:error, {:redirect, %{to: "/login"}}} =
               ctx.view
               |> form("#project-delete-form", confirm: ctx.project.name)
               |> render_submit(%{action: "delete"})

      assert {:ok, _project} = Projects.get(ctx.user, ctx.project.id)
    end
  end

  defp settings(ctx, overrides \\ []) do
    stub(Projects, :settings, fn _, _ ->
      {:ok,
       Enum.into(overrides, %{
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

    render_click(ctx.view, "dialog", %{name: "settings"})
  end
end

defmodule RavixWeb.WorkspaceManagementTest do
  use RavixWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Accounts, People, Previews, Projects, Tracks}
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
      assert attrs == %{"name" => "Selected", "repo" => "acme/app", "installation_id" => 42}
      {:error, {:unavailable, "Provisioning is offline"}}
    end)

    render_click(ctx.view, "dialog", %{name: "new-project"})
    render_change(ctx.view, "installation", %{installation: "42"})
    render_change(ctx.view, "installation", %{installation: "bad-id"})

    ctx.view
    |> form("#new-project-form", new_project: [name: "Selected", repo: "acme/app"])
    |> render_change()

    ctx.view
    |> form("#new-project-form", new_project: [name: "Selected", repo: "acme/app"])
    |> render_submit()

    assert render_async(ctx.view) =~ "Provisioning is offline"
    assert has_element?(ctx.view, "input[name='new_project[name]'][value=Selected]")
    refute has_element?(ctx.view, "#new-project-form button[disabled]")
  end

  for {kind, refs_kind, ref, expected} <- [
        {"blank", nil, nil, %{kind: "blank"}},
        {"branch", :branches, %{name: "release"}, %{kind: "branch", base: "release"}},
        {"pr", :pulls, %{number: 12, title: "Fix", base_ref: "main"},
         %{kind: "pr", number: 12, title: "Fix", base: "main"}},
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
        assert attrs == %{title: "Work", origin: @expected}
        {:error, {:conflict, "busy", "Machine is busy"}}
      end)

      render_click(ctx.view, "dialog", %{name: "new-track"})
      render_click(ctx.view, "origin", %{kind: @kind})

      params =
        if ref,
          do: %{title: "Work", ref: to_string(ref[:number] || ref[:name])},
          else: %{title: "Work"}

      ctx.view |> form("#new-track-form", new_track: params) |> render_submit()
      assert render_async(ctx.view) =~ "Machine is busy"
      refute has_element?(ctx.view, "#new-track-form button[disabled]")
    end
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

    assert render(ctx.view) =~ "Secret updated"
    refute render(ctx.view) =~ "private-value"
  end

  test "an unavailable harness is refused on the box it is about", ctx do
    settings(ctx)

    # `validate_harness/3` answers two codes now, because they are about two
    # inputs: a runtime the catalog does not offer makes every model wrong
    # and is the one to report; past that the harness is fine and the model
    # is not. One code over a two-input form said something true that
    # pointed nowhere.
    for {code, message, id} <- [
          {"invalid_runtime", "Choose a harness this deployment offers.", "#settings-runtime"},
          {"invalid_model", "Choose one of this harness's models.", "#settings-model"}
        ] do
      expect(Projects, :update_settings, fn _, _, _ ->
        {:error, {:unprocessable, code, message}}
      end)

      ctx.view
      |> form("#settings-form", settings: [runtime: "made-up", model: "also-made-up"])
      |> render_submit()

      assert has_element?(ctx.view, "#settings-form .field p.error", message)

      assert has_element?(ctx.view, "#{id}[value='made-up']") or
               has_element?(ctx.view, "#{id}[value='also-made-up']")
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
      |> form("#project-danger-form", confirm: "wrong")
      |> render_submit(%{action: @action})

      assert render(ctx.view) =~ "Type the project name to confirm"

      ctx.view
      |> form("#project-danger-form", confirm: ctx.project.name)
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
    expect(Projects, :create, fn _, _ ->
      {:error, {:unavailable, "no_fountain", "Provisioning is offline."}}
    end)

    ctx.view |> form("#new-project-form", new_project: [name: "Fine"]) |> render_submit()
    assert render_async(ctx.view) =~ "Provisioning is offline."
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
    |> form("#project-danger-form", confirm: ctx.project.name)
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
    |> form("#project-danger-form", confirm: ctx.project.name)
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
    |> form("#project-danger-form", confirm: ctx.project.name)
    |> render_submit(%{action: "rebuild"})

    render_async(ctx.view)
    assert_patch(ctx.view, "/")
    refute render(ctx.view) =~ "would not stop first"
  end

  test "a rebuild that crashes re-enables the buttons and says so", ctx do
    settings(ctx)
    stub(Projects, :rebuild, fn _, _ -> raise "provisioning fell over" end)

    ExUnit.CaptureLog.capture_log(fn ->
      ctx.view
      |> form("#project-danger-form", confirm: ctx.project.name)
      |> render_submit(%{action: "rebuild"})

      render_async(ctx.view)
    end)

    assert render(ctx.view) =~ "The operation could not finish"
    refute has_element?(ctx.view, "button[value=rebuild][disabled]")
  end

  defp settings(ctx) do
    stub(Projects, :settings, fn _, _ ->
      {:ok,
       %{
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

    render_click(ctx.view, "dialog", %{name: "settings"})
  end
end

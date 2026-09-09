defmodule RavixWeb.WorkspaceManagementTest do
  use RavixWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Accounts, People, Previews, Projects, Tracks}

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
    ctx.view |> form("#new-project-form", name: "Selected", repo: "acme/app") |> render_change()
    ctx.view |> form("#new-project-form", name: "Selected", repo: "acme/app") |> render_submit()
    assert render_async(ctx.view) =~ "Provisioning is offline"
    assert has_element?(ctx.view, "input[name=name][value=Selected]")
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

      ctx.view |> form("#new-track-form", params) |> render_submit()
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
    |> form("#secret-form", store: "vault", key: "TOKEN", value: "private-value")
    |> render_submit()

    assert render(ctx.view) =~ "Secret updated"
    refute render(ctx.view) =~ "private-value"
  end

  test "preview defaults can be saved and cleared", ctx do
    settings(ctx)
    # Exercise actual scoped persistence and config validation.
    ctx.view
    |> form("#preview-defaults-form",
      directory: ".",
      command: "PORT=$PORT mix phx.server",
      readiness_path: "/healthz"
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
        :ok
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

  @tag capture_log: true
  test "a crashed provisioning task restores a usable form", ctx do
    expect(Projects, :create, fn _, _ -> raise "provider crashed" end)
    render_click(ctx.view, "dialog", %{name: "new-project"})
    ctx.view |> form("#new-project-form", name: "Keep my work") |> render_submit()
    assert render_async(ctx.view) =~ "The operation could not finish"
    refute has_element?(ctx.view, "#new-project-form button[disabled]")
    assert has_element?(ctx.view, "input[name=name][value='Keep my work']")
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
    People.add_project_member(ctx.project.id, member.id, ctx.user.id)
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
    send(ctx.view.pid, {:hub, %{event: "here"}})
    assert render(ctx.view) =~ ctx.project.name
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
         catalog: nil
       }}
    end)

    render_click(ctx.view, "dialog", %{name: "settings"})
  end
end

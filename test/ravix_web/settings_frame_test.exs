defmodule RavixWeb.SettingsFrameTest do
  @moduledoc """
  RAV-72: settings are pages in the app shell, one URL a section, in one
  frame -- a grouped nav with Danger zone last, a breadcrumb and a title.
  The workspace's pages are `RavixWeb.WorkspaceSettingsLiveTest`'s; the
  personal page is `RavixWeb.ConnectionsLiveTest`'s.
  """
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.Fountain.Shapes.Catalog
  alias RavixWeb.Live.Settings

  setup :verify_on_exit!

  defp stub_settings(project, overrides \\ %{}) do
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)

    stub(Ravix.Projects, :settings, fn _, _ ->
      {:ok,
       Map.merge(
         %{
           name: project.name,
           runtime: "claude",
           model: "model",
           instructions: "",
           setup_script: "",
           packages: %{},
           env_keys: [],
           vault_keys: [],
           catalog: Catalog.empty()
         },
         overrides
       )}
    end)
  end

  defp open(conn, user, path) do
    {:ok, view, _} = live(log_in_user(conn, user), path)
    render_async(view)
    view
  end

  describe "the section lists" do
    test "name every section once, open on the first, and title a page" do
      assert Settings.first(:personal) == "connected-apps"
      assert Settings.first(:workspace) == "general"
      assert Settings.first(:project) == "general"
      assert Settings.section?(:project, "run-script")
      refute Settings.section?(:project, "members")
      refute Settings.section?(:workspace, nil)
      assert Settings.label(:project, "danger") == "Danger zone"
      assert Settings.label(:project, "nope") == "Settings"
      assert Settings.section_path(:personal, nil, "connected-apps") == "/settings/connected-apps"
      assert Settings.section_path(:workspace, "w1", "members") == "/w/w1/settings/members"
      assert Settings.section_path(:project, "p1", "agent") == "/p/p1/settings/agent"
      assert Settings.page_title(:workspace, "members", "Ravi") == "Members · Ravi · Ravix"

      for kind <- [:personal, :workspace, :project] do
        keys = Enum.map(Settings.sections(kind), &elem(&1, 0))
        assert keys == Enum.uniq(keys)
      end
    end

    test "a project's groups end with Danger zone alone, and leave out what is not shown" do
      project = %{id: "p1", display_name: "Atlas"}
      shown = Enum.map(Settings.sections(:project), &elem(&1, 0)) -- ["workspace"]
      groups = Settings.project_groups(project, shown, %{"secrets" => 2})

      assert Enum.map(groups, & &1.label) == ["Atlas", "Machine", nil]
      assert [%{items: [%{key: "danger", danger: true}]}] = Enum.take(groups, -1)
      refute Enum.any?(groups, fn g -> Enum.any?(g.items, &(&1.key == "workspace")) end)

      assert %{count: 2, path: "/p/p1/settings/secrets"} =
               groups |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.key == "secrets"))

      assert [%{label: "Atlas"}] = Settings.project_groups(project, ["general"])
    end

    test "a URL that is not a settings page resolves to nothing" do
      assert Settings.resolve(:home, %{}, %{}) == nil

      assert Settings.resolve(:project_settings, %{"section" => "general"}, %{project: nil}) ==
               :wait
    end
  end

  describe "a project's settings" do
    setup %{conn: conn} do
      user = insert_user()
      project = insert_project(user: user, name: "Atlas")
      %{conn: conn, user: user, project: project}
    end

    test "each section is its own page in the shell, and the nav moves between them", ctx do
      stub_settings(ctx.project, %{
        env_vars: %{"A" => "1", "B" => "2"},
        env_keys: ["TOKEN"],
        vault_keys: ["API", "OTHER"]
      })

      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/agent")

      assert has_element?(view, "#yard")
      assert has_element?(view, ".settings-crumbs li", "Atlas")
      assert has_element?(view, ".settings-crumbs [aria-current=page]", "Agent")
      assert has_element?(view, "#settings-title", "Agent")
      assert page_title(view) == "Agent · Atlas · Ravix"
      assert has_element?(view, "#settings-nav-agent[aria-current=page]")
      assert has_element?(view, "#settings-nav-variables .settings-count", "2")
      assert has_element?(view, "#settings-nav-secrets .settings-count", "3")
      refute has_element?(view, "#settings-nav-general .settings-count")
      assert has_element?(view, ".settings-group.danger:last-child #settings-nav-danger.danger")
      assert has_element?(view, "#settings-section-general[hidden]")
      refute has_element?(view, "#settings-section-agent[hidden]")
      # The project's own page is not drawn under it.
      refute has_element?(view, ".crumbs #crumb-plans")

      # Every section keeps its own Save, and the page asks before leaving
      # one with changes in it (no bar).
      assert has_element?(view, "#project-settings-unsaved[phx-hook=UnsavedChanges]")
      refute has_element?(view, "#project-settings-unsaved-bar")
      assert has_element?(view, "#settings-section-danger[data-unsaved-ignore]")

      view |> element("#settings-nav-danger") |> render_click()
      assert_patch(view, "/p/#{ctx.project.id}/settings/danger")
      assert has_element?(view, "#settings-section-agent[hidden]")
      refute has_element?(view, "#settings-section-danger[hidden]")
      assert page_title(view) == "Danger zone · Atlas · Ravix"
    end

    test "moving to another project's settings shows that project's", ctx do
      other = insert_project(user: ctx.user, name: "Ledger")
      stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)

      stub(Ravix.Projects, :settings, fn _, id ->
        name = if id == other.id, do: "Ledger", else: "Atlas"

        {:ok,
         %{
           name: name,
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

      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/general")
      assert has_element?(view, ~s(#settings-name[value="Atlas"]))
      render_patch(view, "/p/#{other.id}/settings/general")
      render_async(view)
      assert has_element?(view, ~s(#settings-name[value="Ledger"]))
      assert page_title(view) == "General · Ledger · Ravix"
    end

    test "old and bare addresses land on the first section", ctx do
      stub_settings(ctx.project)
      conn = log_in_user(ctx.conn, ctx.user)

      assert redirected_to(get(conn, "/p/#{ctx.project.id}/settings")) ==
               "/p/#{ctx.project.id}/settings/general"

      general = "/p/#{ctx.project.id}/settings/general"

      assert {:error, {:live_redirect, %{to: ^general}}} =
               live(conn, "/p/#{ctx.project.id}?settings=true")
    end

    test "an unknown section, or Workspace with workspaces off, goes to the first", ctx do
      stub_settings(ctx.project)

      conn = log_in_user(ctx.conn, ctx.user)
      general = "/p/#{ctx.project.id}/settings/general"

      for section <- ["nope", "workspace"] do
        assert {:error,
                {:live_redirect, %{to: ^general, flash: %{"info" => "Settings page not found."}}}} =
                 live(conn, "/p/#{ctx.project.id}/settings/#{section}")
      end
    end

    test "another person's project, by id, is not found and draws nothing of it", ctx do
      other = insert_project(user: insert_user(), name: "Theirs")
      reject(&Ravix.Projects.settings/2)
      view = open(ctx.conn, ctx.user, "/p/#{other.id}/settings/general")
      assert_patch(view, "/home")
      assert has_element?(view, "#flash-info", "Project not found.")
      refute has_element?(view, "#settings-sections")
      refute render(view) =~ "Theirs"
    end

    test "a dialog opened over a settings page closes back to it", ctx do
      stub_settings(ctx.project)
      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/secrets")
      view |> element("#open-help") |> render_click()
      assert has_element?(view, "#help-dialog")
      view |> element("#help-dialog button[aria-label=Close]") |> render_click()
      assert_patch(view, "/p/#{ctx.project.id}/settings/secrets")
      refute has_element?(view, "#help-dialog")
      assert has_element?(view, "#settings-sections")
    end

    test "a revoked session cannot save a section", ctx do
      stub_settings(ctx.project)
      reject(&Ravix.Projects.update_settings/3)
      {token, session} = insert_session(ctx.user)
      conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
      {:ok, view, _} = live(conn, "/p/#{ctx.project.id}/settings/general")
      render_async(view)
      Ravix.Repo.delete!(session)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> form("#settings-form", settings: %{name: "Renamed"}) |> render_submit()
    end
  end
end

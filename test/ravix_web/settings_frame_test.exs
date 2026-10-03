defmodule RavixWeb.SettingsFrameTest do
  @moduledoc """
  RAV-72: settings are pages in the app shell, one URL a section, in one
  frame -- a grouped nav with Danger zone last, a breadcrumb and a title.
  RAV-74: a project's are five pages -- General, Access, Agent, Machine and
  Danger zone -- and the dialog's old tabs land on the part they became.
  The workspace's pages are `RavixWeb.WorkspaceSettingsLiveTest`'s; the
  personal page is `RavixWeb.ConnectionsLiveTest`'s.
  """
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.People
  alias RavixWeb.Live.Settings

  setup :verify_on_exit!

  defp stub_settings(project, overrides \\ %{}) do
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)

    stub(Ravix.Projects, :settings, fn _, _ ->
      {:ok,
       Map.merge(
         %{
           env_vars: %{},
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
      assert Settings.first(:personal) == "profile"
      assert Settings.first(:workspace) == "general"
      assert Settings.first(:project) == "general"
      assert Settings.section?(:project, "machine")
      refute Settings.section?(:project, "run-script")
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
      shown = Enum.map(Settings.sections(:project), &elem(&1, 0))
      groups = Settings.project_groups(project, shown, %{"access" => 2})

      assert Enum.map(groups, & &1.label) == ["Atlas", nil]

      assert groups |> hd() |> Map.fetch!(:items) |> Enum.map(& &1.key) ==
               ~w(general access agent machine)

      assert [%{items: [%{key: "danger", danger: true}]}] = Enum.take(groups, -1)

      assert %{count: 2, path: "/p/p1/settings/access"} =
               groups |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.key == "access"))

      assert [%{label: "Atlas"}] = Settings.project_groups(project, ["general"])
    end

    test "the dialog's old tabs are parts of the new pages" do
      project = %{id: "p1", role: :owner, access: :full}

      for {old, to} <- [
            {"environment", "/p/p1/settings/machine#machine-environment"},
            {"variables", "/p/p1/settings/machine#machine-variables"},
            {"secrets", "/p/p1/settings/machine#machine-secrets"},
            {"run-script", "/p/p1/settings/machine#machine-run-script"},
            {"workspace", "/p/p1/settings/general#general-workspace"}
          ] do
        assert Settings.resolve(:project_settings, %{"section" => old}, %{project: project}) ==
                 {:moved, to}
      end

      for kept <- ~w(general agent danger) do
        assert {:ok, %{section: ^kept}} =
                 Settings.resolve(:project_settings, %{"section" => kept}, %{project: project})
      end
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
      stub_settings(ctx.project)
      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/agent")

      assert has_element?(view, "#topbar")
      # The project's own header and tabs give way to the settings frame.
      refute has_element?(view, "header.repo-head")
      assert has_element?(view, ".settings-crumbs li", "Atlas")
      assert has_element?(view, ".settings-crumbs [aria-current=page]", "Agent")
      assert has_element?(view, "#settings-title", "Agent")
      assert page_title(view) == "Agent · Atlas · Ravix"
      assert has_element?(view, "#settings-nav-agent[aria-current=page]")

      for key <- ~w(general access agent machine danger),
          do: assert(has_element?(view, "#settings-nav-#{key}"))

      assert has_element?(view, ".settings-group.danger:last-child #settings-nav-danger.danger")
      # Only the page the URL names is drawn.
      assert has_element?(view, "#settings-section-agent")
      refute has_element?(view, "#settings-section-general")
      # The project's own page is not drawn under it.
      refute has_element?(view, ".crumbs #crumb-plans")

      # One Save a page, in the bar.
      assert has_element?(view, "#project-agent[phx-hook=UnsavedChanges]")
      assert has_element?(view, "#project-agent-bar button[data-unsaved-save]", "Save")

      view |> element("#settings-nav-danger") |> render_click()
      assert_patch(view, "/p/#{ctx.project.id}/settings/danger")
      refute has_element?(view, "#settings-section-agent")
      assert has_element?(view, "#danger-zone[data-unsaved-ignore]")
      refute has_element?(view, "[phx-hook=UnsavedChanges]")
      assert page_title(view) == "Danger zone · Atlas · Ravix"
    end

    test "General shows the name, the repository with a link to GitHub, and the workspace",
         ctx do
      project = insert_project(user: ctx.user, name: "Repo'd", repo_full_name: "octo/atlas")
      stub_settings(project)
      view = open(ctx.conn, ctx.user, "/p/#{project.id}/settings/general")

      assert has_element?(view, "#settings-name")
      assert has_element?(view, "#project-general-bar button[data-unsaved-save]", "Save")
      assert has_element?(view, "#general-repository code", "octo/atlas")

      assert has_element?(
               view,
               ~s(#general-repository-link[href="https://github.com/octo/atlas"][target=_blank][rel~=noopener]),
               "Open on GitHub"
             )

      # A scratch project has none: that is said, and nothing is linked.
      scratch = insert_project(user: ctx.user, name: "Scratch", repo_full_name: nil)
      stub_settings(scratch)
      view = open(ctx.conn, ctx.user, "/p/#{scratch.id}/settings/general")
      assert has_element?(view, "#general-repository", "no repository")
      refute has_element?(view, "#general-repository-link")
    end

    test "Machine gathers the setup, packages, variables, secrets and run script", ctx do
      stub_settings(ctx.project, %{
        setup_script: "npm ci",
        packages: %{"apt" => ["jq"]},
        env_vars: %{"A" => "1"},
        env_keys: ["TOKEN"],
        vault_keys: ["API"]
      })

      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/machine")

      for part <- ~w(machine-environment machine-variables machine-secrets machine-run-script),
          do: assert(has_element?(view, "#machine-form ##{part}"))

      assert has_element?(view, "#settings-setup", "npm ci")
      assert has_element?(view, "#packages-apt[value=jq]")
      assert has_element?(view, "#env-var-key-0[value=A]")
      assert has_element?(view, "#secret-key-env-TOKEN", "Environment")
      assert has_element?(view, "#secret-key-vault-API", "Vault")
      assert has_element?(view, "#default-command")
      # One Save for all of it, and it says what it does.
      assert has_element?(
               view,
               "#project-machine-bar button[data-unsaved-save]",
               "Save & rebuild"
             )

      assert has_element?(view, "#project-machine-bar button[form=machine-form]")
    end

    test "settings Fountain cannot read are said so; Access, which is Ravix's own, still shows",
         ctx do
      stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)
      stub(Ravix.Projects, :settings, fn _, _ -> {:error, {:unavailable, "Try later"}} end)
      reject(&Ravix.Projects.update_settings/3)

      for section <- ~w(general agent machine danger) do
        view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/#{section}")
        assert has_element?(view, "#settings-unavailable", "could not be read")
        assert has_element?(view, "#settings-nav-#{section}[aria-current=page]")
      end

      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/access")
      refute has_element?(view, "#settings-unavailable")
      assert has_element?(view, "#project-access-person-#{ctx.user.login}", "owner")
    end

    test "an old tab's address opens the page it is part of, at that part", ctx do
      stub_settings(ctx.project)
      conn = log_in_user(ctx.conn, ctx.user)

      for {old, to} <- [
            {"secrets", "machine#machine-secrets"},
            {"run-script", "machine#machine-run-script"},
            {"workspace", "general#general-workspace"}
          ] do
        path = "/p/#{ctx.project.id}/settings/#{to}"

        assert {:error, {:live_redirect, %{to: ^path}}} =
                 live(conn, "/p/#{ctx.project.id}/settings/#{old}")
      end

      # And from a page already open, a patch.
      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/general")
      render_patch(view, "/p/#{ctx.project.id}/settings/variables")
      # The test client drops the fragment it was sent; the first case above
      # shows it is sent.
      assert_patch(view, "/p/#{ctx.project.id}/settings/variables")
      assert assert_patch(view) =~ "/p/#{ctx.project.id}/settings/machine"
      assert has_element?(view, "#settings-nav-machine[aria-current=page]")
      assert has_element?(view, "#machine-variables")
    end

    test "moving to another project's settings shows that project's", ctx do
      other = insert_project(user: ctx.user, name: "Ledger")
      stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)

      stub(Ravix.Projects, :settings, fn _, id ->
        name = if id == other.id, do: "Ledger", else: "Atlas"

        {:ok,
         %{
           env_vars: %{},
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

    test "an unknown section goes to the first", ctx do
      stub_settings(ctx.project)

      conn = log_in_user(ctx.conn, ctx.user)
      general = "/p/#{ctx.project.id}/settings/general"

      for section <- ["nope", "members"] do
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
      refute has_element?(view, "#settings-page")
      refute render(view) =~ "Theirs"
    end

    test "a member who is not the owner is sent to the project, on every page", ctx do
      member = insert_user()
      People.Store.add_project_member(ctx.project.id, member.id, ctx.user.id)
      # A direct Admin is still not the owner: settings are `project_of/2`'s.
      {:ok, _} = People.set_project_role(ctx.user, ctx.project.id, member.login, "admin")
      reject(&Ravix.Projects.settings/2)
      conn = log_in_user(ctx.conn, member)

      project_path = "/p/#{ctx.project.id}"

      for section <- ~w(general access agent machine danger secrets) do
        assert {:error,
                {:live_redirect,
                 %{
                   to: ^project_path,
                   flash: %{"info" => "Only the project's owner can change its settings."}
                 }}} = live(conn, "/p/#{ctx.project.id}/settings/#{section}")
      end

      # Nor from a page already open, by a patch.
      {:ok, view, _} = live(conn, project_path)
      render_async(view)
      render_patch(view, "/p/#{ctx.project.id}/settings/machine")
      assert_patch(view, project_path)
      refute has_element?(view, "#settings-page")

      # Their People is still the dialog, and there is no Settings for them.
      {:ok, view, _} = live(conn, "/p/#{ctx.project.id}")
      render_async(view)
      refute has_element?(view, "#crumb-settings")
      refute has_element?(view, "#crumb-people")
      view |> element(".crumbs button", "People") |> render_click()
      assert has_element?(view, "#people-dialog")
    end

    test "the owner reaches settings from the project header's People and Settings tabs", ctx do
      stub_settings(ctx.project)
      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}")
      assert has_element?(view, ~s(#crumb-settings[href="/p/#{ctx.project.id}/settings/general"]))
      view |> element("#crumb-people") |> render_click()
      assert_patch(view, "/p/#{ctx.project.id}/settings/access")
      assert has_element?(view, "#project-access-person-#{ctx.user.login}", "owner")

      render_patch(view, "/p/#{ctx.project.id}")
      view |> element("#crumb-settings") |> render_click()
      assert_patch(view, "/p/#{ctx.project.id}/settings/general")
    end

    test "a dialog opened over a settings page closes back to it", ctx do
      stub_settings(ctx.project)
      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/machine")
      view |> element("#open-help") |> render_click()
      assert has_element?(view, "#help-dialog")
      view |> element("#help-dialog button[aria-label=Close]") |> render_click()
      assert_patch(view, "/p/#{ctx.project.id}/settings/machine")
      refute has_element?(view, "#help-dialog")
      assert has_element?(view, "#machine-form")
    end

    test "the project's People dialog (RAV-75) opens over a settings page and closes back", ctx do
      stub_settings(ctx.project)
      view = open(ctx.conn, ctx.user, "/p/#{ctx.project.id}/settings/agent")
      render_click(view, "dialog", %{name: "people"})
      assert has_element?(view, "#people-dialog")
      assert has_element?(view, "#settings-page")
      view |> element("#people-dialog button[aria-label=Close]") |> render_click()
      refute_patched(view)
      refute has_element?(view, "#people-dialog")
      assert has_element?(view, "#settings-nav-agent[aria-current=page]")
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

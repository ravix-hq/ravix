defmodule RavixWeb.ProjectMoveLiveTest do
  @moduledoc """
  "Move to workspace…" in project settings: offered to the owner, only
  towards workspaces they own or administer, behind a confirmation that
  says who gains visibility; a same-repository target points to the
  project already there; open pages on both sides re-read after the move.

  Not async: the tests flip `RAVIX_WORKSPACE_ACCESS`, which is application-wide.
  """
  use RavixWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Projects
  alias Ravix.Projects.Project
  alias Ravix.Workspaces
  alias Ravix.Workspaces.Store

  setup :verify_on_exit!

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude, :codex]} end)

    owner = insert_user(login: "owner")
    boss = insert_user(login: "boss")
    {:ok, _personal} = Store.ensure_personal_workspace(owner)
    {:ok, acme} = Workspaces.create(owner, "Acme")
    {:ok, beta} = Workspaces.create(boss, "Beta")
    :ok = Store.add_member(beta.id, owner.id, :admin, boss.id)
    {:ok, gamma} = Workspaces.create(boss, "Gamma")
    :ok = Store.add_member(gamma.id, owner.id, :member, boss.id)

    project = insert_project(user: owner, name: "app", repo_full_name: "owner/app")
    1 = Store.move_project(project.id, acme.id)

    %{owner: owner, boss: boss, acme: acme, beta: beta, gamma: gamma, project: project}
  end

  defp open_settings(ctx) do
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

    {:ok, view, _html} = live(log_in_user(build_conn(), ctx.owner), "/p/#{ctx.project.id}")
    render_async(view)
    render_click(view, "dialog", %{name: "settings"})
    render_async(view)
    view
  end

  defp workspace_of(%Project{id: id}), do: Ravix.Repo.get!(Project, id).workspace_id

  test "the owner confirms who gains visibility, then moves the project", ctx do
    view = open_settings(ctx)

    assert has_element?(view, "[data-settings-section=workspace]", "Workspace")
    assert has_element?(view, "#settings-section-workspace", "This project is in Acme.")
    assert has_element?(view, "#move-to-#{ctx.beta.id}", "Move to Beta…")
    refute has_element?(view, "#move-to-#{ctx.gamma.id}")
    refute has_element?(view, "#move-to-#{ctx.acme.id}")
    assert has_element?(view, "#move-targets button", "Move to your personal workspace…")

    view |> element("#move-to-#{ctx.beta.id}") |> render_click()
    assert has_element?(view, "#move-confirmation", "Move app to Beta?")

    assert has_element?(
             view,
             "#move-confirmation",
             "Members of Beta will see this project and its workspace-visible tracks"
           )

    assert has_element?(view, "#move-confirmation", "Private tracks stay private.")
    assert has_element?(view, "#move-confirmation", "People who reach it only through Acme")

    view |> element("#move-confirmation button", "Cancel") |> render_click()
    refute has_element?(view, "#move-confirmation")
    assert workspace_of(ctx.project) == ctx.acme.id

    view |> element("#move-to-#{ctx.beta.id}") |> render_click()
    view |> element("#confirm-move") |> render_click()
    render_async(view)

    assert workspace_of(ctx.project) == ctx.beta.id
    assert render(view) =~ "Moved to Beta."
    refute has_element?(view, "#move-confirmation")
    assert has_element?(view, "#settings-section-workspace", "This project is in Beta.")
    assert has_element?(view, "#move-to-#{ctx.acme.id}", "Move to Acme…")
  end

  test "a target with the same repository points to the project already there", ctx do
    existing = insert_project(user: ctx.boss, name: "Beta app", repo_full_name: "OWNER/app")
    1 = Store.move_project(existing.id, ctx.beta.id)

    view = open_settings(ctx)
    view |> element("#move-to-#{ctx.beta.id}") |> render_click()
    view |> element("#confirm-move") |> render_click()
    render_async(view)

    assert workspace_of(ctx.project) == ctx.acme.id
    assert has_element?(view, "#move-taken", "Beta already has a project for this repository")
    assert has_element?(view, ~s|#move-taken a[href="/p/#{existing.id}"]|, "Beta app")
    refute has_element?(view, "#move-confirmation")
  end

  test "open pages re-read: Acme's members lose it and Beta's gain it", ctx do
    acme_member = insert_user(login: "acmeone")
    :ok = Store.add_member(ctx.acme.id, acme_member.id, :member, ctx.owner.id)
    beta_member = insert_user(login: "betaone")
    :ok = Store.add_member(ctx.beta.id, beta_member.id, :member, ctx.boss.id)
    # Beta's member has something open on Beta already, which is how their
    # rail hears about Beta.
    other = insert_project(user: ctx.boss, repo_full_name: "boss/other")
    1 = Store.move_project(other.id, ctx.beta.id)

    {:ok, leaving, _} = live(log_in_user(build_conn(), acme_member), "/p/#{ctx.project.id}")
    render_async(leaving)
    {:ok, joining, _} = live(log_in_user(build_conn(), beta_member), "/p/#{other.id}")
    render_async(joining)
    refute render(joining) =~ ~s|/p/#{ctx.project.id}"|

    view = open_settings(ctx)
    view |> element("#move-to-#{ctx.beta.id}") |> render_click()
    view |> element("#confirm-move") |> render_click()
    render_async(view)

    assert_patch(leaving, "/")
    render_async(joining)
    assert render(joining) =~ ~s|/p/#{ctx.project.id}"|
  end

  test "with workspaces switched off there is no Workspace section", ctx do
    Application.put_env(:ravix, :workspace_access, false)
    view = open_settings(ctx)
    assert has_element?(view, "#settings-form")
    refute has_element?(view, "#settings-section-workspace")
    refute has_element?(view, "[data-settings-section=workspace]")
  end

  test "an owner with nowhere else to go is told why" do
    solo = insert_user(login: "solo")
    {:ok, personal} = Store.ensure_personal_workspace(solo)
    lonely = insert_project(user: solo, name: "lonely", repo_full_name: "solo/lonely")
    1 = Store.move_project(lonely.id, personal.id)

    view = open_settings(%{owner: solo, project: lonely})
    assert has_element?(view, "#move-no-targets", "owner or admin")
    assert has_element?(view, "#settings-section-workspace", "your personal workspace")
    refute has_element?(view, "#move-targets")
  end
end

defmodule RavixWeb.ProjectAccessPageTest do
  @moduledoc """
  RAV-74: the project's People dialog is the Access settings page for its
  owner, `/p/:project/settings/access`. It lists everyone who reaches the
  project with where their role comes from (RAV-75) and changes roles in
  place; it re-reads when the people change, and stays owner-only through
  `Access.project_of/2` on every event.

  Not async: the tests turn on `RAVIX_WORKSPACE_ACCESS`, which is
  application-wide.
  """
  use RavixWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Hub.Event
  alias Ravix.{People, Repo}
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

    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)

    owner = insert_user(login: "owner")
    alice = insert_user(login: "alice")
    carol = insert_user(login: "carol")
    {:ok, team} = Workspaces.create(owner, "Team")
    :ok = Store.add_member(team.id, alice.id, :member, owner.id)
    :ok = Store.add_member(team.id, carol.id, :member, owner.id)
    project = insert_project(user: owner, name: "Atlas", repo_full_name: "owner/atlas")
    1 = Store.move_project(project.id, team.id)
    {:ok, _} = People.set_project_role(owner, project.id, "alice", "read")

    stub(Ravix.Projects, :settings, fn _, _ ->
      {:ok,
       %{
         env_vars: %{},
         name: "Atlas",
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

    %{owner: owner, alice: alice, carol: carol, team: team, project: project}
  end

  defp open(conn, user, project) do
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}/settings/access")
    render_async(view)
    view
  end

  test "everyone who reaches the project, with their role and its source", ctx do
    view = open(ctx.conn, ctx.owner, ctx.project)
    assert page_title(view) == "Access · Atlas · Ravix"
    assert has_element?(view, "#settings-nav-access[aria-current=page]")
    refute has_element?(view, "#project-access-dialog")

    summary = "#project-access-summary"
    assert has_element?(view, summary, "Base role: Write")
    assert has_element?(view, summary, "Direct access: 1 person")
    assert has_element?(view, summary, "3 Team members get Write by default")

    assert has_element?(view, "#project-access-person-owner", "Admin")
    assert has_element?(view, "#project-access-person-owner", "owner")
    assert has_element?(view, "#project-access-person-alice", "Read")
    assert has_element?(view, "#project-access-person-alice", "direct")
    assert has_element?(view, "#project-access-person-carol", "Write")
    assert has_element?(view, "#project-access-person-carol", "from workspace")
    # The copy link stays; a workspace project has no invitation.
    assert has_element?(view, "#project-access-copy-link")
    refute has_element?(view, "#project-access-invite-form")
  end

  test "giving a different role and taking it back, on the page", ctx do
    view = open(ctx.conn, ctx.owner, ctx.project)

    view
    |> element("#project-access-person-carol button[phx-value-role=admin]")
    |> render_click()

    assert has_element?(view, "#project-access-person-carol", "direct")
    assert has_element?(view, "#project-access-summary", "Direct access: 2 people")

    assert {:ok, %{level: :admin}} =
             Ravix.Accounts.Access.project_access(ctx.carol, ctx.project.id)

    view
    |> element("#project-access-person-carol button", "Use workspace role (Write)")
    |> render_click()

    assert has_element?(view, "#project-access-person-carol", "from workspace")
    # Taking a grant away is not leaving: the page stays where it is.
    refute_patched(view)
    assert has_element?(view, "#settings-nav-access[aria-current=page]")
  end

  test "somebody else's change re-reads the page", ctx do
    view = open(ctx.conn, ctx.owner, ctx.project)
    {:ok, _} = People.set_project_role(ctx.owner, ctx.project.id, "carol", "read")
    send(view.pid, {:hub, Event.new(:people, ctx.project.id)})
    render_async(view)
    assert has_element?(view, "#project-access-person-carol", "direct")
    assert has_element?(view, "#project-access-summary", "Direct access: 2 people")
  end

  test "a member, even a direct Admin, is not let in; nor is a stranger", ctx do
    {:ok, _} = People.set_project_role(ctx.owner, ctx.project.id, "alice", "admin")
    project_path = "/p/#{ctx.project.id}"

    assert {:error, {:live_redirect, %{to: ^project_path}}} =
             live(log_in_user(ctx.conn, ctx.alice), "#{project_path}/settings/access")

    {:ok, view, _} = live(log_in_user(ctx.conn, insert_user()), "#{project_path}/settings/access")
    render_async(view)
    assert_patch(view, "/home")
    refute has_element?(view, "#project-access")
  end

  test "a revoked session cannot change a role from the page", ctx do
    {token, session} = insert_session(ctx.owner)
    conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
    {:ok, view, _} = live(conn, "/p/#{ctx.project.id}/settings/access")
    render_async(view)
    Repo.delete!(session)
    reject(&People.set_project_role/4)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view
             |> element("#project-access-person-carol button[phx-value-role=read]")
             |> render_click()
  end

  test "another person's login is refused, and nothing changes", ctx do
    stranger = insert_user(login: "stranger")
    view = open(ctx.conn, ctx.owner, ctx.project)

    view
    |> element("#project-access-person-carol button[phx-value-role=read]")
    |> render_click(%{"login" => stranger.login})

    assert {:error, :not_found} = Ravix.Accounts.Access.project_access(stranger, ctx.project.id)
    assert has_element?(view, "#project-access-person-carol", "from workspace")
    refute has_element?(view, "#project-access-person-stranger")
  end

  test "the owner's ownership lost mid-page refuses the next event", ctx do
    view = open(ctx.conn, ctx.owner, ctx.project)
    Ravix.Accounts.Access |> stub(:project_of, fn _, _ -> {:error, :not_found} end)
    reject(&People.set_project_role/4)

    # The Machine page's events go through `project_of/2` before anything.
    render_patch(view, "/p/#{ctx.project.id}/settings/machine")
    view |> element("button", "Add secret") |> render_click()
    refute has_element?(view, ".secret-row")
    assert render(view) =~ "No such thing here."
  end
end

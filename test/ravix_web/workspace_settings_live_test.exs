defmodule RavixWeb.WorkspaceSettingsLiveTest do
  @moduledoc """
  ADR 0009 phase 4a in the browser's terms: the sidebar's workspace
  switcher, creating a workspace from it, and a workspace's settings in the
  settings frame (RAV-72, RAV-73): General; Members with its role list,
  invitations and role controls; Repositories; Projects; and Danger zone.
  All of it hidden while `RAVIX_WORKSPACE_ACCESS` is off.

  Not async: the tests flip the switch, which is application-wide.
  """
  use RavixWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Ravix.GitHubFake, as: Fake
  alias Ravix.Hub.Event
  alias Ravix.Workspaces
  alias Ravix.Workspaces.Store

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    # GitHub knows @dana, who has not signed in here, and whoever holds a
    # login locally; anything else is a 404.
    Fake.install(Fake.app_reader_routes() ++ [Fake.users_route(%{"dana" => {9001, "dana"}})])

    stub(Ravix.Config, :github, fn -> Fake.app() end)

    owner = insert_user(login: "owner")
    {:ok, personal} = Store.ensure_personal_workspace(owner)
    {:ok, team} = Workspaces.create(owner, "Acme")
    %{owner: owner, personal: personal, team: team}
  end

  defp switch(on?), do: Application.put_env(:ravix, :workspace_access, on?)

  defp open(user, workspace_id, section \\ "members") do
    {:ok, view, html} =
      live(log_in_user(build_conn(), user), "/w/#{workspace_id}/settings/#{section}")

    {view, html}
  end

  describe "the sidebar switcher" do
    test "lists the personal workspace first, then teams, and creates one", ctx do
      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.owner), "/home")

      links = view |> element("#workspace-menu [role=group]") |> render()
      assert links =~ "Personal"
      [personal_at, team_at] = Enum.map([ctx.personal.id, ctx.team.id], &:binary.match(links, &1))
      assert personal_at < team_at

      # "New workspace…" is a menu item that opens a small dialog.
      refute has_element?(view, "#new-workspace-form")
      view |> element("#new-workspace", "New workspace…") |> render_click()
      assert has_element?(view, "#new-workspace-dialog #new-workspace-form")
      view |> form("#new-workspace-form", name: "Beta") |> render_submit()

      path = assert_patch(view)
      assert ["", "w", id, "settings", "members"] = String.split(path, "/")
      refute has_element?(view, "#new-workspace-dialog")
      assert has_element?(view, "#settings-title", "Members")
      assert {:ok, %{workspace: %{name: "Beta"}, role: :owner}} = Workspaces.people(ctx.owner, id)
      # The new workspace is the one the app now shows.
      assert Ravix.Repo.reload!(ctx.owner).current_workspace_id == id
    end

    test "an empty name is refused where it was typed", ctx do
      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.owner), "/home")
      render_click(view, "dialog", %{name: "new-workspace"})
      html = view |> form("#new-workspace-form", name: "  ") |> render_submit()
      assert html =~ "Give the workspace a name."
    end

    test "with the switch off there is no switcher and no workspace page", ctx do
      switch(false)
      conn = log_in_user(build_conn(), ctx.owner)
      {:ok, view, _html} = live(conn, "/home")
      refute has_element?(view, "#workspace-switcher")

      assert {:error,
              {:live_redirect, %{to: "/home", flash: %{"info" => "Workspace not found."}}}} =
               live(conn, "/w/#{ctx.team.id}/settings/members")
    end
  end

  describe "a workspace's page" do
    test "an owner invites a known user and a pending login, and revokes the invitation", ctx do
      insert_user(login: "bo")
      {view, html} = open(ctx.owner, ctx.team.id)
      assert html =~ "Acme"

      # Suggestions come from people who have signed in here.
      view |> form("#workspace-invite-form", login: "b") |> render_change()
      assert has_element?(view, "#workspace-invite-suggestions option[value=bo]")

      view |> form("#workspace-invite-form", login: "bo", role: "admin") |> render_submit()
      assert has_element?(view, "#workspace-members", "@bo")

      view |> form("#workspace-invite-form", login: "dana") |> render_submit()
      assert render(view) =~ "They join when they first sign in."
      assert has_element?(view, "#invite-dana", "@dana")

      view |> element("#invite-dana button", "Revoke") |> render_click()
      refute has_element?(view, "#invite-dana")
      assert Store.invites(ctx.team.id) == []

      view |> form("#workspace-invite-form", login: "nobody") |> render_submit()
      assert render(view) =~ "There is no GitHub user called @nobody."
    end

    test "an owner changes a role and removes a member; the page follows others' changes", ctx do
      bo = insert_user(login: "bo")
      :ok = Store.add_member(ctx.team.id, bo.id, :member, ctx.owner.id)
      {view, _html} = open(ctx.owner, ctx.team.id)

      view |> form("#role-#{bo.id}", user: bo.id, role: "admin") |> render_change()
      assert %{role: :admin} = Store.membership(ctx.team.id, bo.id)

      view |> element("#member-#{bo.id} button", "Remove") |> render_click()
      refute has_element?(view, "#member-#{bo.id}")

      # Somebody else's invitation reaches the open page on the hub notice.
      # The page passes the notice on to the settings component, one
      # message later.
      {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      _ = render(view)
      assert render(view) =~ "invite-dana"
    end

    test "a member sees the people but none of the controls", ctx do
      member = insert_user(login: "mem")
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)
      {view, html} = open(member, ctx.team.id)

      assert html =~ "@owner"
      refute has_element?(view, "#workspace-invite-form")
      refute has_element?(view, "button", "Remove")
      refute has_element?(view, "#role-#{member.id}")

      # A forged event is refused by the context all the same.
      view
      |> with_target("#workspace-settings-content")
      |> render_hook("invite", %{"login" => "dana"})

      html = render(view)
      assert html =~ "Your role in this workspace cannot do that."
      assert Store.invites(ctx.team.id) == []
    end

    test "an admin cannot withdraw an owner's invitation, and is not offered to", ctx do
      admin = insert_user(login: "adm")
      :ok = Store.add_member(ctx.team.id, admin.id, :admin, ctx.owner.id)
      {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      {view, _html} = open(admin, ctx.team.id)

      assert has_element?(view, "#invite-dana")
      refute has_element?(view, "#invite-dana button", "Revoke")

      view
      |> with_target("#workspace-settings-content")
      |> render_hook("revoke-invite", %{"login" => "dana"})

      html = render(view)

      assert html =~ "Only an owner can change or withdraw"
      assert [_] = Store.invites(ctx.team.id)
    end

    test "a stranger, and another tenant's id, are not found", ctx do
      stranger = insert_user()
      {:ok, other} = Workspaces.create(stranger, "Other")
      conn = log_in_user(build_conn(), ctx.owner)

      for id <- [other.id, "does-not-exist"] do
        assert {:error,
                {:live_redirect, %{to: "/home", flash: %{"info" => "Workspace not found."}}}} =
                 live(conn, "/w/#{id}/settings/members")
      end
    end

    test "a member removed while the page is open is sent home", ctx do
      member = insert_user(login: "mem")
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)
      {view, _html} = open(member, ctx.team.id)

      :ok = Workspaces.remove_member(ctx.owner, ctx.team.id, member.id)
      # The page leaves on the Hub's broadcast, after re-reading membership:
      # wait for that navigation rather than the 100ms default.
      assert_redirect(view, "/", 1_000)
    end

    test "a member removed just before a rail read, unheard, is still sent home", ctx do
      member = insert_user(login: "mem")
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)
      {view, _html} = open(member, ctx.team.id)
      render_async(view)

      # The removal commits, and the page's next rail read lands before its
      # `:members` notice: that read unsubscribes from the workspace, so the
      # notice is never heard. Revoke without publishing, then read.
      {:ok, _} = Store.revoke_membership(ctx.team.id, member.id, ctx.owner.id)
      send(view.pid, {:hub, %Event{name: :tracks, project_id: Ecto.UUID.generate()}})

      assert_redirect(view, "/", 1_000)
    end

    test "a personal workspace has no invite box", ctx do
      {view, html} = open(ctx.owner, ctx.personal.id)
      assert html =~ "A personal workspace is yours alone."
      refute has_element?(view, "#workspace-invite-form")
    end

    test "opening a workspace's settings makes it current, in the app shell", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id)
      assert has_element?(view, "#topbar #account-trigger")
      assert has_element?(view, ".settings-crumbs", "Acme")
      assert has_element?(view, ".settings-crumbs [aria-current=page]", "Members")
      assert has_element?(view, "#settings-nav-members[aria-current=page] .settings-count", "1")
      assert page_title(view) == "Members · Acme · Ravix"
      assert view |> element("#workspace-switcher-trigger") |> render() =~ "Acme"
      assert has_element?(view, "#workspace-select-#{ctx.team.id}[aria-current=true]")
      # The current one is ticked, and only it (RAV-96).
      assert has_element?(view, "#workspace-select-#{ctx.team.id} .menu-check svg")
      refute has_element?(view, "#workspace-select-#{ctx.personal.id} .menu-check svg")
      assert Ravix.Repo.reload!(ctx.owner).current_workspace_id == ctx.team.id
    end

    test "switching workspace keeps the section, in the new workspace", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id, "general")

      view |> element("#workspace-select-#{ctx.personal.id}") |> render_click()
      assert_patch(view, "/w/#{ctx.personal.id}/settings/general")
      assert has_element?(view, "#workspace-kind", "Personal workspace")
      assert Ravix.Repo.reload!(ctx.owner).current_workspace_id == ctx.personal.id
    end

    test "the old address and the bare one land on Members, query and all", ctx do
      conn = log_in_user(build_conn(), ctx.owner)

      assert redirected_to(get(conn, "/w/#{ctx.team.id}")) ==
               "/w/#{ctx.team.id}/settings/members"

      assert redirected_to(get(conn, "/w/#{ctx.team.id}/settings")) ==
               "/w/#{ctx.team.id}/settings/members"

      assert redirected_to(get(conn, "/w/#{ctx.team.id}?github=connected")) ==
               "/w/#{ctx.team.id}/settings/members?github=connected"
    end

    test "an unknown section goes to the first one", ctx do
      conn = log_in_user(build_conn(), ctx.owner)
      to = "/w/#{ctx.team.id}/settings/general"

      assert {:error,
              {:live_redirect, %{to: ^to, flash: %{"info" => "Settings page not found."}}}} =
               live(conn, "/w/#{ctx.team.id}/settings/nope")
    end
  end

  defp in_workspace(project, workspace_id),
    do: project |> Ecto.Changeset.change(workspace_id: workspace_id) |> Ravix.Repo.update!()

  defp add(ctx, login, role) do
    user = insert_user(login: login)
    :ok = Store.add_member(ctx.team.id, user.id, role, ctx.owner.id)
    user
  end

  describe "every section" do
    test "has its own URL on the frame, in nav order, Danger zone alone and last", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id, "projects")

      for {key, label} <- [
            {"general", "General"},
            {"members", "Members"},
            {"repositories", "Repositories"},
            {"projects", "Projects"},
            {"danger", "Danger zone"}
          ] do
        assert has_element?(
                 view,
                 ~s(#settings-nav-#{key}[href="/w/#{ctx.team.id}/settings/#{key}"]),
                 label
               )

        view |> element("#settings-nav-#{key}") |> render_click()
        assert_patch(view, "/w/#{ctx.team.id}/settings/#{key}")
        assert has_element?(view, "#settings-title", label)
        assert page_title(view) == "#{label} · Acme · Ravix"
      end

      assert has_element?(view, ".settings-group.danger #settings-nav-danger.danger")
      refute has_element?(view, ".settings-group.danger #settings-nav-members")
    end
  end

  describe "Members" do
    test "says what each role can do, and an owner is offered all three", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id)

      for role <- ~w(owner admin member),
          do: assert(has_element?(view, "#workspace-roles [data-role=#{role}] dd"))

      assert has_element?(
               view,
               "#workspace-roles [data-role=admin]",
               "Invites and removes members"
             )

      for role <- ~w(member admin owner),
          do: assert(has_element?(view, "#workspace-invite-role option[value=#{role}]"))
    end

    test "the chosen role survives the redraw a suggestion causes, and is the one granted", ctx do
      bo = insert_user(login: "bo")
      {view, _html} = open(ctx.owner, ctx.team.id)

      view |> form("#workspace-invite-form", login: "b", role: "admin") |> render_change()
      assert has_element?(view, "#workspace-invite-role option[value=admin][selected]")

      view |> form("#workspace-invite-form", login: "bo", role: "admin") |> render_submit()
      assert %{role: :admin} = Store.membership(ctx.team.id, bo.id)
      # And back to Member for the next one.
      assert has_element?(view, "#workspace-invite-role option[value=member][selected]")
    end

    test "an admin is offered Member only, and a forged Admin is refused", ctx do
      admin = add(ctx, "adm", :admin)
      insert_user(login: "bo")
      {view, _html} = open(admin, ctx.team.id)

      assert has_element?(view, "#workspace-invite-role option[value=member]")
      refute has_element?(view, "#workspace-invite-role option[value=admin]")

      view
      |> with_target("#workspace-settings-content")
      |> render_hook("invite", %{"login" => "bo", "role" => "admin"})

      assert render(view) =~ "Your role in this workspace cannot do that."
      assert length(Store.members(ctx.team.id)) == 2
    end
  end

  describe "Repositories" do
    test "shows the connections and the catalog, with Configure on GitHub for owners and admins",
         ctx do
      {:ok, installation} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
      # Read just now, so opening the page does not ask GitHub again.
      :ok = Store.record_refresh(installation, :active, nil, [])
      admin = add(ctx, "adm", :admin)
      member = add(ctx, "mem", :member)

      for user <- [ctx.owner, admin] do
        {view, _html} = open(user, ctx.team.id, "repositories")
        assert has_element?(view, "#workspace-installations", "@acme")
        link = view |> element("#configure-github") |> render()
        assert link =~ ~s(target="_blank")
        assert link =~ ~s(rel="noopener noreferrer")
        assert link =~ "/installations/new"
        refute link =~ "state="
      end

      {view, _html} = open(member, ctx.team.id, "repositories")
      assert has_element?(view, "#workspace-installations", "@acme")
      refute has_element?(view, "#configure-github")
      refute has_element?(view, "#connect-github")
    end

    test "Members no longer carries GitHub", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id, "members")
      refute has_element?(view, "#workspace-github")
    end

    test "Settings › Profile › Repository access links the current workspace's Repositories",
         ctx do
      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.owner), "/settings/profile")
      current = Ravix.Repo.reload!(ctx.owner).current_workspace_id || ctx.personal.id

      view |> element("#profile-workspace-repositories") |> render_click()
      assert_patch(view, "/w/#{current}/settings/repositories")
      assert has_element?(view, "#settings-title", "Repositories")
    end
  end

  describe "Projects" do
    test "lists each project with owner, repository, agent and people", ctx do
      member = add(ctx, "mem", :member)

      mine =
        insert_project(user: ctx.owner, name: "web", repo_full_name: "acme/web", runtime: "codex")
        |> in_workspace(ctx.team.id)

      theirs =
        insert_project(user: member, name: "notes", repo_full_name: nil)
        |> in_workspace(ctx.team.id)

      {view, _html} = open(ctx.owner, ctx.team.id, "projects")
      assert has_element?(view, "#settings-nav-projects .settings-count", "2")
      row = "#workspace-project-#{mine.id}"
      assert has_element?(view, "#{row} th a[href='/p/#{mine.id}']", "web")
      assert has_element?(view, "#{row} td", "@owner")
      assert has_element?(view, "#{row} td", "acme/web")
      assert has_element?(view, "#{row} td", "Codex")
      assert has_element?(view, "#{row} td", "2")
      assert has_element?(view, "#{row} a[href='/p/#{mine.id}/settings/general']")

      # Somebody else's project: no settings link, whose settings are theirs.
      assert has_element?(view, "#workspace-project-#{theirs.id} td", "No repository")
      refute has_element?(view, "#workspace-project-#{theirs.id} a[href$='/settings/general']")
    end

    test "an empty workspace points at Repositories", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id, "projects")

      assert has_element?(
               view,
               ~s(#workspace-projects-empty a[href="/w/#{ctx.team.id}/settings/repositories"])
             )
    end
  end

  describe "Danger zone" do
    test "a member leaves and is sent home", ctx do
      member = add(ctx, "mem", :member)
      {view, _html} = open(member, ctx.team.id, "danger")
      refute has_element?(view, "#delete-workspace-form")
      assert has_element?(view, "#delete-owner-only")

      assert {:error, {:live_redirect, %{to: "/home"}}} =
               view |> element("#leave-workspace") |> render_click()

      assert %{"info" => "You left Acme."} = assert_redirect(view, "/home")

      assert Store.membership(ctx.team.id, member.id) == nil
    end

    test "the last owner is told why they cannot leave", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id, "danger")
      view |> element("#leave-workspace") |> render_click()
      assert render(view) =~ "only owner"
      assert Store.membership(ctx.team.id, ctx.owner.id)
    end

    test "a personal workspace offers neither leave nor delete, and refuses a forged leave",
         ctx do
      {view, _html} = open(ctx.owner, ctx.personal.id, "danger")
      refute has_element?(view, "#leave-workspace")
      refute has_element?(view, "#delete-workspace-form")

      view |> with_target("#workspace-settings-content") |> render_hook("leave", %{})
      assert render(view) =~ "You cannot leave your personal workspace."
      assert Store.membership(ctx.personal.id, ctx.owner.id)
    end

    test "an owner deletes with the name typed; others' open pages leave", ctx do
      member = add(ctx, "mem", :member)
      {other, _html} = open(member, ctx.team.id, "members")
      {view, _html} = open(ctx.owner, ctx.team.id, "danger")

      assert has_element?(view, "#delete-workspace-form button[disabled]")
      view |> form("#delete-workspace-form", confirm: "Acme") |> render_change()
      refute has_element?(view, "#delete-workspace-form button[disabled]")

      view |> form("#delete-workspace-form", confirm: "nope") |> render_submit()
      assert render(view) =~ "Type the workspace&#39;s name to delete it."
      assert Store.live_workspace(ctx.team.id)

      assert {:error, {:live_redirect, %{to: "/home"}}} =
               view |> form("#delete-workspace-form", confirm: "Acme") |> render_submit()

      assert %{"info" => "Deleted Acme."} = assert_redirect(view, "/home")

      assert Store.live_workspace(ctx.team.id) == nil
      assert_redirect(other, "/")
    end

    test "a workspace with projects cannot be deleted yet", ctx do
      insert_project(user: ctx.owner) |> in_workspace(ctx.team.id)
      {view, _html} = open(ctx.owner, ctx.team.id, "danger")
      assert has_element?(view, "#delete-workspace-form button[disabled]")

      view
      |> with_target("#workspace-settings-content")
      |> render_hook("delete", %{"confirm" => "Acme"})

      assert render(view) =~ "Acme still has 1 project."
      assert Store.live_workspace(ctx.team.id)
    end

    test "an admin's forged delete is refused", ctx do
      admin = add(ctx, "adm", :admin)
      {view, _html} = open(admin, ctx.team.id, "danger")
      refute has_element?(view, "#delete-workspace-form")

      view
      |> with_target("#workspace-settings-content")
      |> render_hook("delete", %{"confirm" => "Acme"})

      assert render(view) =~ "Your role in this workspace cannot do that."
      assert Store.live_workspace(ctx.team.id)
    end

    test "a revoked session can neither leave nor delete", ctx do
      member = add(ctx, "mem", :member)

      for {user, event, params} <- [
            {member, "leave", %{}},
            {ctx.owner, "delete", %{"confirm" => "Acme"}}
          ] do
        {token, session} = insert_session(user)
        conn = Plug.Test.init_test_session(build_conn(), session_token: token)
        {:ok, view, _html} = live(conn, "/w/#{ctx.team.id}/settings/danger")
        Ravix.Repo.delete!(session)

        assert {:error, {:redirect, %{to: "/login"}}} =
                 view |> with_target("#workspace-settings-content") |> render_hook(event, params)
      end

      assert Store.membership(ctx.team.id, member.id)
      assert Store.live_workspace(ctx.team.id)
    end

    test "somebody removed while the page is open cannot delete and is sent home", ctx do
      other_owner = add(ctx, "own2", :owner)
      {view, _html} = open(other_owner, ctx.team.id, "danger")
      # An owner's page reads their own GitHub accounts in the background;
      # let that answer first, or it is what notices the removal.
      render_async(view)

      # Removed without the notice reaching the page: the event itself asks.
      assert {:ok, _} = Store.revoke_membership(ctx.team.id, other_owner.id, ctx.owner.id)

      assert {:error, {:redirect, %{to: "/"}}} =
               view
               |> with_target("#workspace-settings-content")
               |> render_hook("delete", %{"confirm" => "Acme"})

      assert Store.live_workspace(ctx.team.id)
    end

    test "another workspace's danger zone is not found", ctx do
      stranger = insert_user()
      {:ok, other} = Workspaces.create(stranger, "Other")

      assert {:error,
              {:live_redirect, %{to: "/home", flash: %{"info" => "Workspace not found."}}}} =
               live(log_in_user(build_conn(), ctx.owner), "/w/#{other.id}/settings/danger")

      assert Store.live_workspace(other.id)
    end
  end

  describe "General" do
    test "offers New workspace…, which opens the dialog", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id, "general")
      view |> element("#general-new-workspace") |> render_click()
      assert has_element?(view, "#new-workspace-dialog #new-workspace-form")
    end

    test "an owner renames the workspace; the switcher and title follow", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id, "general")
      assert has_element?(view, "#workspace-general-unsaved-bar[hidden]")

      assert has_element?(
               view,
               ~s(#workspace-general-unsaved-bar button[form="workspace-general-form"]),
               "Save"
             )

      assert has_element?(view, "#workspace-kind", "Team workspace")

      view |> form("#workspace-general-form", workspace: %{name: "  "}) |> render_submit()
      assert has_element?(view, "#workspace-general-form", "Give the workspace a name.")
      assert Store.live_workspace(ctx.team.id).name == "Acme"

      view |> form("#workspace-general-form", workspace: %{name: "Acme Labs"}) |> render_submit()
      assert Store.live_workspace(ctx.team.id).name == "Acme Labs"
      assert has_element?(view, ~s(#workspace-general-unsaved[data-saved="1"]))
      assert render(view) =~ "Workspace renamed."
      assert view |> element("#workspace-switcher-trigger") |> render() =~ "Acme Labs"
      assert page_title(view) == "General · Acme Labs · Ravix"
    end

    test "Discard draws the saved name again", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id, "general")
      view |> form("#workspace-general-form", workspace: %{name: ""}) |> render_submit()
      view |> with_target("#workspace-settings-content") |> render_hook("discard-general", %{})
      assert has_element?(view, ~s(#workspace-name[value="Acme"]))
    end

    test "an admin renames; a member sees the name and cannot", ctx do
      admin = insert_user(login: "adm")
      member = insert_user(login: "mem")
      :ok = Store.add_member(ctx.team.id, admin.id, :admin, ctx.owner.id)
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)

      {view, _html} = open(admin, ctx.team.id, "general")
      view |> form("#workspace-general-form", workspace: %{name: "By admin"}) |> render_submit()
      assert Store.live_workspace(ctx.team.id).name == "By admin"

      {view, _html} = open(member, ctx.team.id, "general")
      refute has_element?(view, "#workspace-general-form")
      assert has_element?(view, "#workspace-name-shown", "By admin")

      view
      |> with_target("#workspace-settings-content")
      |> render_hook("rename", %{"workspace" => %{"name" => "Forged"}})

      html = render(view)

      assert html =~ "Your role in this workspace cannot do that."
      assert Store.live_workspace(ctx.team.id).name == "By admin"
    end

    test "a revoked session cannot rename", ctx do
      {token, session} = insert_session(ctx.owner)
      conn = Plug.Test.init_test_session(build_conn(), session_token: token)
      {:ok, view, _html} = live(conn, "/w/#{ctx.team.id}/settings/general")

      Ravix.Repo.delete!(session)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#workspace-general-form", workspace: %{name: "After"})
               |> render_submit()

      assert Store.live_workspace(ctx.team.id).name == "Acme"
    end

    test "a member removed while the page is open cannot rename and is sent home", ctx do
      admin = insert_user(login: "adm")
      :ok = Store.add_member(ctx.team.id, admin.id, :admin, ctx.owner.id)
      {view, _html} = open(admin, ctx.team.id, "general")
      # A rail read after the removal would send the page home by itself
      # (`leave_lost_settings/1`); this is the event's own check.
      render_async(view)

      # Removed without the notice reaching the page: the event itself asks.
      assert {:ok, _} = Store.revoke_membership(ctx.team.id, admin.id, ctx.owner.id)

      assert {:error, {:redirect, %{to: "/"}}} =
               view
               |> form("#workspace-general-form", workspace: %{name: "After"})
               |> render_submit()

      assert Store.live_workspace(ctx.team.id).name == "Acme"
    end
  end
end

defmodule RavixWeb.WorkspaceSettingsLiveTest do
  @moduledoc """
  ADR 0009 phase 4a in the browser's terms: the sidebar's workspace
  switcher, creating a workspace from it, and a workspace's settings in the
  settings frame (RAV-72): General, and Members with its invitations and
  role controls. All of it hidden while `RAVIX_WORKSPACE_ACCESS` is off.

  Not async: the tests flip the switch, which is application-wide.
  """
  use RavixWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Ravix.GitHubFake, as: Fake
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
      assert_redirect(view, "/")
    end

    test "a personal workspace has no invite box", ctx do
      {view, html} = open(ctx.owner, ctx.personal.id)
      assert html =~ "A personal workspace is yours alone."
      refute has_element?(view, "#workspace-invite-form")
    end

    test "opening a workspace's settings makes it current, in the app shell", ctx do
      {view, _html} = open(ctx.owner, ctx.team.id)
      assert has_element?(view, "#yard")
      assert has_element?(view, ".settings-crumbs", "Acme")
      assert has_element?(view, ".settings-crumbs [aria-current=page]", "Members")
      assert has_element?(view, "#settings-nav-members[aria-current=page] .settings-count", "1")
      assert page_title(view) == "Members · Acme · Ravix"
      assert view |> element("#workspace-switcher-trigger") |> render() =~ "Acme"
      assert has_element?(view, "#workspace-select-#{ctx.team.id}[aria-current=true]")
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

  describe "General" do
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

defmodule RavixWeb.WorkspacePeopleLiveTest do
  @moduledoc """
  ADR 0009 phase 4a in the browser's terms: the sidebar's workspace
  switcher, creating a workspace from it, and a workspace's page with its
  members, invitations and role controls. All of it hidden while
  `RAVIX_WORKSPACE_ACCESS` is off.

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
    Fake.install([Fake.users_route(%{"dana" => {9001, "dana"}})])

    stub(Ravix.Config, :github, fn -> Fake.app() end)

    owner = insert_user(login: "owner")
    {:ok, personal} = Store.ensure_personal_workspace(owner)
    {:ok, team} = Workspaces.create(owner, "Acme")
    %{owner: owner, personal: personal, team: team}
  end

  defp switch(on?), do: Application.put_env(:ravix, :workspace_access, on?)

  describe "the sidebar switcher" do
    test "lists the personal workspace first, then teams, and creates one", ctx do
      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.owner), "/home")

      links = view |> element("#workspace-menu nav") |> render()
      assert links =~ "Personal"
      [personal_at, team_at] = Enum.map([ctx.personal.id, ctx.team.id], &:binary.match(links, &1))
      assert personal_at < team_at

      assert {:error, {:live_redirect, %{to: "/w/" <> id}}} =
               view |> form("#new-workspace-form", name: "Beta") |> render_submit()

      assert {:ok, %{workspace: %{name: "Beta"}, role: :owner}} = Workspaces.people(ctx.owner, id)
    end

    test "an empty name is refused where it was typed", ctx do
      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.owner), "/home")
      html = view |> form("#new-workspace-form", name: "  ") |> render_submit()
      assert html =~ "Give the workspace a name."
    end

    test "with the switch off there is no switcher and no workspace page", ctx do
      switch(false)
      conn = log_in_user(build_conn(), ctx.owner)
      {:ok, view, _html} = live(conn, "/home")
      refute has_element?(view, "#workspace-switcher")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/w/#{ctx.team.id}")
    end
  end

  describe "a workspace's page" do
    test "an owner invites a known user and a pending login, and revokes the invitation", ctx do
      insert_user(login: "bo")
      {:ok, view, html} = live(log_in_user(build_conn(), ctx.owner), "/w/#{ctx.team.id}")
      assert html =~ "Acme"

      # Suggestions come from people who have signed in here.
      view |> form("#workspace-invite-form", login: "b") |> render_change()
      assert has_element?(view, "#workspace-invite-suggestions option[value=bo]")

      view |> form("#workspace-invite-form", login: "bo", role: "admin") |> render_submit()
      assert has_element?(view, "#workspace-members", "@bo")

      html = view |> form("#workspace-invite-form", login: "dana") |> render_submit()
      assert html =~ "They join when they first sign in."
      assert has_element?(view, "#invite-dana", "@dana")

      view |> element("#invite-dana button", "Revoke") |> render_click()
      refute has_element?(view, "#invite-dana")
      assert Store.invites(ctx.team.id) == []

      html = view |> form("#workspace-invite-form", login: "nobody") |> render_submit()
      assert html =~ "There is no GitHub user called @nobody."
    end

    test "an owner changes a role and removes a member; the page follows others' changes", ctx do
      bo = insert_user(login: "bo")
      :ok = Store.add_member(ctx.team.id, bo.id, :member, ctx.owner.id)
      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.owner), "/w/#{ctx.team.id}")

      view |> form("#role-#{bo.id}", user: bo.id, role: "admin") |> render_change()
      assert %{role: :admin} = Store.membership(ctx.team.id, bo.id)

      view |> element("#member-#{bo.id} button", "Remove") |> render_click()
      refute has_element?(view, "#member-#{bo.id}")

      # Somebody else's invitation reaches the open page on the hub notice.
      {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      assert render(view) =~ "invite-dana"
    end

    test "a member sees the people but none of the controls", ctx do
      member = insert_user(login: "mem")
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)
      {:ok, view, html} = live(log_in_user(build_conn(), member), "/w/#{ctx.team.id}")

      assert html =~ "@owner"
      refute has_element?(view, "#workspace-invite-form")
      refute has_element?(view, "button", "Remove")
      refute has_element?(view, "#role-#{member.id}")

      # A forged event is refused by the context all the same.
      html = render_hook(view, "invite", %{"login" => "dana"})
      assert html =~ "Your role in this workspace cannot do that."
      assert Store.invites(ctx.team.id) == []
    end

    test "an admin cannot withdraw an owner's invitation, and is not offered to", ctx do
      admin = insert_user(login: "adm")
      :ok = Store.add_member(ctx.team.id, admin.id, :admin, ctx.owner.id)
      {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      {:ok, view, _html} = live(log_in_user(build_conn(), admin), "/w/#{ctx.team.id}")

      assert has_element?(view, "#invite-dana")
      refute has_element?(view, "#invite-dana button", "Revoke")

      html = render_hook(view, "revoke-invite", %{"login" => "dana"})
      assert html =~ "Only an owner can change or withdraw"
      assert [_] = Store.invites(ctx.team.id)
    end

    test "a stranger, and another tenant's id, are not found", ctx do
      stranger = insert_user()
      {:ok, other} = Workspaces.create(stranger, "Other")
      conn = log_in_user(build_conn(), ctx.owner)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/w/#{other.id}")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/w/does-not-exist")
    end

    test "a member removed while the page is open is sent home", ctx do
      member = insert_user(login: "mem")
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)
      {:ok, view, _html} = live(log_in_user(build_conn(), member), "/w/#{ctx.team.id}")

      :ok = Workspaces.remove_member(ctx.owner, ctx.team.id, member.id)
      assert_redirect(view, "/")
    end

    test "a personal workspace has no invite box", ctx do
      {:ok, view, html} = live(log_in_user(build_conn(), ctx.owner), "/w/#{ctx.personal.id}")
      assert html =~ "A personal workspace is yours alone."
      refute has_element?(view, "#workspace-invite-form")
    end

    test "the switcher on the page names the current workspace and creates another", ctx do
      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.owner), "/w/#{ctx.team.id}")
      assert view |> element("#workspace-switcher-trigger") |> render() =~ "Acme"

      assert has_element?(
               view,
               ~s(#workspace-menu a[aria-current=page][href="/w/#{ctx.team.id}"])
             )

      assert {:error, {:live_redirect, %{to: "/w/" <> _}}} =
               view |> form("#new-workspace-form", name: "Gamma") |> render_submit()
    end
  end
end

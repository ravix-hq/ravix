defmodule RavixWeb.WorkspaceGitHubTest do
  @moduledoc """
  ADR 0009 phase 4b at the request boundary: "Connect GitHub" redirects to
  GitHub with a state, GitHub's return to `/api/auth/callback` binds the
  installation for the browser session that began it and not for another,
  and the workspace page shows connections and the catalog and adds a
  repository.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on, application-wide.
  """
  use RavixWeb.ConnCase, async: false
  use Mimic

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Ravix.WorkspaceGitHubFixture

  alias Ravix.Fountain.FakeTransport
  alias Ravix.GitHub.Shapes
  alias Ravix.Repo
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Backfill, Installation, Repositories, Store}
  alias RavixWeb.Live.Guard

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    app =
      github(
        %{
          77 => %{account: "acme", repos: [repo(1, "acme/api"), repo(2, "acme/web")]},
          55 => %{account: "victim", repos: [repo(9, "victim/secret")]},
          88 => %{account: "owner", type: "User", repos: [repo(20, "owner/dotfiles")]}
        },
        %{"owner-code" => [77, 88]}
      )

    stub(Ravix.Config, :github, fn -> app end)

    # Signed in with the token GitHub's "owner-code" buys, so their own
    # installations (77 and 88) read as they would in production.
    owner =
      insert_user(
        login: "owner",
        credential_set_id: "set-me",
        token_enc: Ravix.Crypto.encrypt("user-owner-code")
      )

    {:ok, team} = Workspaces.create(owner, "Acme")
    %{owner: owner, team: team, conn: log_in_user(build_conn(), owner)}
  end

  defp state_of(location) do
    %{"state" => state} = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    state
  end

  describe "the connect round trip" do
    test "connect redirects to GitHub; the callback binds and lands on the workspace", ctx do
      conn = get(ctx.conn, "/w/#{ctx.team.id}/github/connect")
      location = redirected_to(conn, 302)
      assert location =~ "https://github.test/apps/test/installations/new?state="
      state = state_of(location)

      back =
        ctx.conn
        |> get(
          "/api/auth/callback?installation_id=77&setup_action=install&code=owner-code&state=#{state}"
        )

      assert redirected_to(back) == "/w/#{ctx.team.id}/settings/members?github=connected"
      assert [%Installation{installation_id: 77}] = Store.installations(ctx.team.id)

      # The same callback again is a replay.
      again =
        ctx.conn
        |> get(
          "/api/auth/callback?installation_id=77&setup_action=install&code=owner-code&state=#{state}"
        )

      assert redirected_to(again) ==
               "/w/#{ctx.team.id}/settings/members?github_error=stale_connect"
    end

    test "another browser session, or nobody signed in, cannot finish it", ctx do
      state =
        ctx.conn |> get("/w/#{ctx.team.id}/github/connect") |> redirected_to(302) |> state_of()

      other = log_in_user(build_conn(), ctx.owner)

      assert other
             |> get("/api/auth/callback?installation_id=77&code=owner-code&state=#{state}")
             |> redirected_to() == "/w/#{ctx.team.id}/settings/members?github_error=stale_connect"

      assert build_conn()
             |> get("/api/auth/callback?installation_id=77&code=owner-code&state=#{state}")
             |> redirected_to() =~ "/w/#{ctx.team.id}/settings/members?github_error="

      assert Store.installations(ctx.team.id) == []
    end

    test "a member, a stranger and a signed-out browser cannot begin", ctx do
      member = insert_user()
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)

      assert log_in_user(build_conn(), member)
             |> get("/w/#{ctx.team.id}/github/connect")
             |> Map.get(:status) ==
               403

      assert log_in_user(build_conn(), insert_user())
             |> get("/w/#{ctx.team.id}/github/connect")
             |> Map.get(:status) == 404

      assert build_conn() |> get("/w/#{ctx.team.id}/github/connect") |> Map.get(:status) == 401
    end

    test "somebody else's installation id is refused and nothing is bound", ctx do
      state =
        ctx.conn |> get("/w/#{ctx.team.id}/github/connect") |> redirected_to(302) |> state_of()

      assert ctx.conn
             |> get("/api/auth/callback?installation_id=55&code=owner-code&state=#{state}")
             |> redirected_to() ==
               "/w/#{ctx.team.id}/settings/members?github_error=not_your_installation"

      assert Store.installations(ctx.team.id) == []
    end

    test "a callback without GitHub's code is refused", ctx do
      state =
        ctx.conn |> get("/w/#{ctx.team.id}/github/connect") |> redirected_to(302) |> state_of()

      assert ctx.conn
             |> get("/api/auth/callback?installation_id=77&setup_action=install&state=#{state}")
             |> redirected_to() ==
               "/w/#{ctx.team.id}/settings/members?github_error=no_authorization"

      assert Store.installations(ctx.team.id) == []
    end

    test "a callback whose state names no workspace goes home", ctx do
      assert ctx.conn
             |> get("/api/auth/callback?installation_id=77&state=ws.")
             |> redirected_to() == "/?error=stale_connect"
    end
  end

  describe "the workspace page" do
    test "shows Connect GitHub, the connections and the catalog, and adds a repository", ctx do
      {:ok, _} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
      {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)

      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}/settings/members")
      assert has_element?(view, ~s(#connect-github[href="/w/#{ctx.team.id}/github/connect"]))

      assert has_element?(
               view,
               "#workspace-installations li[data-account=acme][data-status=active]",
               "@acme"
             )

      assert has_element?(view, "li[data-repo='acme/web']", "acme/web")

      provisioning(1)
      view |> element("li[data-repo='acme/web'] button", "Add") |> render_click()
      {path, _flash} = assert_redirect(view)
      assert "/p/" <> project_id = path

      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}/settings/members")

      assert has_element?(
               view,
               ~s(li[data-repo="acme/web"] a[href="/p/#{project_id}"]),
               "Open project"
             )
    end

    test "a stale catalog is refreshed in the background once the page connects", ctx do
      {:ok, _} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}/settings/members")
      render_async(view)
      assert has_element?(view, "li[data-repo='acme/api']", "acme/api")
    end

    test "a revoked connection shows why, and its repositories are gone", ctx do
      {:ok, _} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
      {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)
      github(%{77 => %{account: "acme", gone: true}})

      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}/settings/members")
      view |> element("#refresh-catalog") |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "#workspace-installations li[data-account=acme][data-status=revoked]",
               "uninstalled from @acme"
             )

      refute has_element?(view, "#workspace-catalog")
    end

    test "a member sees the catalog but neither Connect nor Add", ctx do
      {:ok, _} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
      {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)
      member = insert_user()
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), member), "/w/#{ctx.team.id}/settings/members")

      refute has_element?(view, "#connect-github")
      assert has_element?(view, "li[data-repo='acme/web']", "Not added yet")
      refute has_element?(view, "li[data-repo='acme/web'] button")

      # A forged add is refused by the context all the same.
      view
      |> with_target("#workspace-settings-content")
      |> render_hook("add-repo", %{"repo" => "acme/web"})

      html = render_async(view)
      assert html =~ "Your role in this workspace cannot do that."
    end

    test "adding a repository whose project is archived says so and does not crash", ctx do
      {:ok, _} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
      {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)

      archived =
        insert_project(
          user: ctx.owner,
          repo_full_name: "acme/web",
          archived_at: DateTime.utc_now()
        )

      Store.move_project(archived.id, ctx.team.id)
      client = provisioning(0)

      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}/settings/members")
      view |> element("li[data-repo='acme/web'] button", "Add") |> render_click()
      html = render_async(view)
      assert html =~ "archived or being deleted"
      assert Process.alive?(view.pid)
      assert FakeTransport.calls(client) == []
    end

    test "landing from GitHub says what happened", ctx do
      {:ok, _view, html} = live(ctx.conn, "/w/#{ctx.team.id}/settings/members?github=connected")
      assert html =~ "GitHub connected."

      {:ok, _view, html} =
        live(ctx.conn, "/w/#{ctx.team.id}/settings/members?github_error=stale_connect")

      assert html =~ "expired or was already used"
    end
  end

  # What waiting out `Guard.ttl_ms/0` amounts to; see the same helper in
  # `RavixWeb.WorkspaceLiveTest`.
  defp age_session_guard(state) do
    update_in(state.socket.assigns.session_guard, fn guard ->
      %{guard | verified_at_ms: guard.verified_at_ms - Guard.ttl_ms() - 1}
    end)
  end

  describe "RAV-69: the accounts a workspace uses" do
    # A project on acme/api that reached the team before the catalog did,
    # through installation 77, with no connection row: production's state.
    defp predating_project(ctx) do
      project =
        insert_project(user: ctx.owner, repo_full_name: "acme/api", installation_id: 77)

      1 = Store.move_project(project.id, ctx.team.id)
      Repo.delete_all(from i in Installation, where: i.workspace_id == ^ctx.team.id)
      project
    end

    test "a workspace whose project predates the catalog shows connected after the backfill",
         ctx do
      predating_project(ctx)
      admin = insert_user()
      :ok = Store.add_member(ctx.team.id, admin.id, :admin, ctx.owner.id)
      admin_conn = log_in_user(build_conn(), admin)

      {:ok, view, _html} = live(admin_conn, "/w/#{ctx.team.id}/settings/members")
      assert has_element?(view, "#github-empty", "No GitHub account is connected yet.")

      Backfill.run()

      {:ok, view, _html} = live(admin_conn, "/w/#{ctx.team.id}/settings/members")
      refute has_element?(view, "#github-empty")

      assert has_element?(
               view,
               "#workspace-installations li[data-account=acme][data-status=active]",
               "Connected"
             )

      # The never-read connection is read once the page connects.
      render_async(view)
      assert has_element?(view, "li[data-repo='acme/api']", "Open project")
      assert has_element?(view, "li[data-repo='acme/web'] button", "Add")
    end

    test "the empty state offers the owner's own accounts, and Add connects one", ctx do
      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}/settings/members")
      render_async(view)

      assert has_element?(view, "#github-empty", "Add one of yours")
      assert has_element?(view, "#available-77[data-account=acme] button", "Add to workspace")
      assert has_element?(view, "#available-88", "Personal account")
      # Somebody else's installation is never offered.
      refute has_element?(view, "#available-55")
      # The empty state's action is Add, not a fresh install.
      assert has_element?(view, "#connect-github.ghost")

      view |> element("#available-77 button") |> render_click()
      render_async(view)
      assert render(view) =~ "Added @acme to this workspace."

      assert [%Installation{installation_id: 77, account_login: "acme"} = connection] =
               Store.installations(ctx.team.id)

      assert connection.connected_by_user_id == ctx.owner.id
      assert has_element?(view, "#workspace-installations li[data-account=acme]", "Connected")
      assert has_element?(view, "li[data-repo='acme/api']")
      refute has_element?(view, "#available-77")
      assert has_element?(view, "#available-88")
    end

    test "Add is refused for an admin and a member, who are never offered it", ctx do
      for role <- [:admin, :member] do
        person = insert_user(token_enc: Ravix.Crypto.encrypt("user-owner-code"))
        :ok = Store.add_member(ctx.team.id, person.id, role, ctx.owner.id)

        {:ok, view, _html} =
          live(log_in_user(build_conn(), person), "/w/#{ctx.team.id}/settings/members")

        render_async(view)
        refute has_element?(view, "#available-installations")

        view
        |> with_target("#workspace-settings-content")
        |> render_hook("add-installation", %{"installation" => "77"})

        assert render_async(view) =~ "Your role in this workspace cannot do that."
      end

      assert Store.installations(ctx.team.id) == []
    end

    test "Add is refused for an installation the owner cannot see on GitHub", ctx do
      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}/settings/members")
      render_async(view)

      view
      |> with_target("#workspace-settings-content")
      |> render_hook("add-installation", %{"installation" => "55"})

      assert render_async(view) =~ "not one you can see"
      assert Store.installations(ctx.team.id) == []
    end

    test "a revoked session cannot add", ctx do
      {token, session} = insert_session(ctx.owner)
      conn = Plug.Test.init_test_session(build_conn(), session_token: token)
      {:ok, view, _html} = live(conn, "/w/#{ctx.team.id}/settings/members")
      render_async(view)
      Repo.delete!(session)
      :sys.replace_state(view.pid, &age_session_guard/1)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> element("#available-77 button") |> render_click()

      assert Store.installations(ctx.team.id) == []
    end

    test "onboarding's GitHub step names the same accounts the workspace uses", ctx do
      predating_project(ctx)
      Backfill.run()
      {:ok, _} = Ravix.Accounts.put_current_workspace(ctx.owner, ctx.team.id)

      stub(Ravix.Projects, :repos, fn _user, id ->
        {:ok,
         %{
           installations: [
             %Shapes.Installation{id: 77, account: "acme", avatar_url: nil},
             %Shapes.Installation{id: 88, account: "owner", avatar_url: nil}
           ],
           repos: [],
           selected: id || 77
         }}
      end)

      {:ok, view, _html} = live(ctx.conn, "/welcome/github")
      render_async(view)

      assert has_element?(view, "#github-connected", "Connected to acme, owner.")
      assert has_element?(view, "#github-workspace-in", "Acme uses @acme.")
      assert has_element?(view, "#github-workspace-out", "Not in Acme yet: @owner.")

      assert has_element?(
               view,
               ~s(#github-workspace-out a[href="/w/#{ctx.team.id}/settings/members#workspace-github"]),
               "Add to workspace"
             )
    end
  end
end

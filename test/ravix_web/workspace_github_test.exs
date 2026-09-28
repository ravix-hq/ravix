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

  import Phoenix.LiveViewTest
  import Ravix.WorkspaceGitHubFixture

  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Installation, Repositories, Store}

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    app = github(%{77 => %{account: "acme", repos: [repo(1, "acme/api"), repo(2, "acme/web")]}})
    stub(Ravix.Config, :github, fn -> app end)

    owner = insert_user(login: "owner", credential_set_id: "set-me")
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
        |> get("/api/auth/callback?installation_id=77&setup_action=install&state=#{state}")

      assert redirected_to(back) == "/w/#{ctx.team.id}?github=connected"
      assert [%Installation{installation_id: 77}] = Store.installations(ctx.team.id)

      # The same callback again is a replay.
      again =
        ctx.conn
        |> get("/api/auth/callback?installation_id=77&setup_action=install&state=#{state}")

      assert redirected_to(again) == "/w/#{ctx.team.id}?github_error=stale_connect"
    end

    test "another browser session, or nobody signed in, cannot finish it", ctx do
      state =
        ctx.conn |> get("/w/#{ctx.team.id}/github/connect") |> redirected_to(302) |> state_of()

      other = log_in_user(build_conn(), ctx.owner)

      assert other
             |> get("/api/auth/callback?installation_id=77&state=#{state}")
             |> redirected_to() == "/w/#{ctx.team.id}?github_error=stale_connect"

      assert build_conn()
             |> get("/api/auth/callback?installation_id=77&state=#{state}")
             |> redirected_to() =~ "/w/#{ctx.team.id}?github_error="

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

      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}")
      assert has_element?(view, ~s(#connect-github[href="/w/#{ctx.team.id}/github/connect"]))
      assert has_element?(view, "#installation-77[data-status=active]", "@acme")
      assert has_element?(view, "#repo-2", "acme/web")

      provisioning(1)
      view |> element("#repo-2 button", "Add") |> render_click()
      {path, _flash} = assert_redirect(view)
      assert "/p/" <> project_id = path

      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}")
      assert has_element?(view, ~s(#repo-2 a[href="/p/#{project_id}"]), "Open project")
    end

    test "a stale catalog is refreshed in the background once the page connects", ctx do
      {:ok, _} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}")
      render_async(view)
      assert has_element?(view, "#repo-1", "acme/api")
    end

    test "a revoked connection shows why, and its repositories are gone", ctx do
      {:ok, _} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
      {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)
      github(%{77 => %{account: "acme", gone: true}})

      {:ok, view, _html} = live(ctx.conn, "/w/#{ctx.team.id}")
      view |> element("#refresh-catalog") |> render_click()
      render_async(view)

      assert has_element?(view, "#installation-77[data-status=revoked]", "uninstalled from @acme")
      refute has_element?(view, "#workspace-catalog")
    end

    test "a member sees the catalog but neither Connect nor Add", ctx do
      {:ok, _} = Store.bind_installation(ctx.team.id, 77, "acme", ctx.owner.id)
      {:ok, _} = Repositories.refresh(ctx.owner, ctx.team.id)
      member = insert_user()
      :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)

      {:ok, view, _html} = live(log_in_user(build_conn(), member), "/w/#{ctx.team.id}")
      refute has_element?(view, "#connect-github")
      assert has_element?(view, "#repo-2", "Not added yet")
      refute has_element?(view, "#repo-2 button")

      # A forged add is refused by the context all the same.
      render_hook(view, "add-repo", %{"repo" => "acme/web"})
      html = render_async(view)
      assert html =~ "Your role in this workspace cannot do that."
    end

    test "landing from GitHub says what happened", ctx do
      {:ok, _view, html} = live(ctx.conn, "/w/#{ctx.team.id}?github=connected")
      assert html =~ "GitHub connected."

      {:ok, _view, html} = live(ctx.conn, "/w/#{ctx.team.id}?github_error=stale_connect")
      assert html =~ "expired or was already used"
    end
  end
end

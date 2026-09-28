defmodule Ravix.Workspaces.ConnectTest do
  @moduledoc """
  ADR 0009 phase 4b: connecting a GitHub installation to a workspace. The
  state is single-use, bound to its workspace, person and session, and
  expires; the installation must exist on GitHub; one installation may be
  bound to several workspaces.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on, application-wide.
  """
  use Ravix.DataCase, async: false
  use Mimic

  import Ravix.Factory
  import Ravix.WorkspaceGitHubFixture

  alias Ravix.Workspaces
  alias Ravix.Workspaces.{CatalogRepo, Connect, ConnectState, Installation, Store}

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    # Installation 55 exists for the App (somebody else's), but only 77 is
    # visible to the person whose GitHub `code` is "owner-code".
    app =
      github(
        %{
          77 => %{account: "acme", repos: [repo(1, "acme/api"), repo(2, "acme/web")]},
          55 => %{account: "victim", repos: [repo(9, "victim/secret")]}
        },
        %{"owner-code" => [77], "victim-code" => [55]}
      )

    stub(Ravix.Config, :github, fn -> app end)

    owner = insert_user(login: "owner")
    {:ok, team} = Workspaces.create(owner, "Acme")
    %{owner: owner, team: team, app: app}
  end

  defp begin!(user, workspace, session \\ "session-a") do
    {:ok, url} = Connect.begin(user, workspace.id, session)
    %{"state" => state} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {url, state}
  end

  test "an owner connects: GitHub's page, then the callback binds and fills the catalog", ctx do
    {url, state} = begin!(ctx.owner, ctx.team)
    assert url =~ "/apps/test/installations/new?state="
    assert Connect.state?(state)
    assert Connect.workspace_of(state) == ctx.team.id
    # Only a hash is stored; the nonce itself never is.
    refute Repo.exists?(from s in ConnectState, where: s.key_hash == ^state)

    Ravix.Hub.subscribe_workspace(ctx.team.id)
    team_id = ctx.team.id
    assert {:ok, ^team_id} = Connect.finish(ctx.owner, "session-a", state, "77", "owner-code")
    assert_receive {:workspace_hub, ^team_id, :members}

    assert [%Installation{installation_id: 77, account_login: "acme", revoked_at: nil} = inst] =
             Store.installations(ctx.team.id)

    assert inst.connected_by_user_id == ctx.owner.id

    assert Store.catalog(ctx.team.id) |> Enum.map(& &1.full_name) |> Enum.sort() ==
             ["acme/api", "acme/web"]
  end

  test "the state is single-use: a replay is refused", ctx do
    {_url, state} = begin!(ctx.owner, ctx.team)
    assert {:ok, _} = Connect.finish(ctx.owner, "session-a", state, "77", "owner-code")
    assert {:error, :stale} = Connect.finish(ctx.owner, "session-a", state, "77", "owner-code")
  end

  test "a state is bound to its workspace, its person and its session", ctx do
    {_url, state} = begin!(ctx.owner, ctx.team)
    {:ok, other} = Workspaces.create(ctx.owner, "Other")
    "ws." <> rest = state
    [_team, nonce] = String.split(rest, ".", parts: 2)

    # The same nonce, retargeted at another workspace the person also owns.
    assert {:error, :stale} =
             Connect.finish(ctx.owner, "session-a", "ws.#{other.id}.#{nonce}", "77", "owner-code")

    # Another person, or another browser session, holding the URL.
    stranger = insert_user()
    assert {:error, :stale} = Connect.finish(stranger, "session-a", state, "77", "owner-code")
    assert {:error, :stale} = Connect.finish(ctx.owner, "session-b", state, "77", "owner-code")

    # None of those spent it; the rightful callback still lands, once.
    assert {:ok, _} = Connect.finish(ctx.owner, "session-a", state, "77", "owner-code")
    assert Store.installations(other.id) == []
  end

  test "a state expires after fifteen minutes", ctx do
    {_url, state} = begin!(ctx.owner, ctx.team)

    Repo.update_all(ConnectState,
      set: [created_at: DateTime.add(DateTime.utc_now(), -16, :minute)]
    )

    assert {:error, :stale} = Connect.finish(ctx.owner, "session-a", state, "77", "owner-code")
    assert Store.installations(ctx.team.id) == []
  end

  test "malformed states and installation ids are refused", ctx do
    assert {:error, :stale} = Connect.finish(ctx.owner, "session-a", "ws.", "77", "owner-code")

    assert {:error, :stale} =
             Connect.finish(ctx.owner, "session-a", "not-a-connect-state", "77", "owner-code")

    assert {:error, :stale} = Connect.finish(ctx.owner, nil, "ws.x.y", "77", "owner-code")
    refute Connect.state?(nil)

    {_url, state} = begin!(ctx.owner, ctx.team)

    assert {:error, {:unprocessable, "no_installation", _}} =
             Connect.finish(ctx.owner, "session-a", state, "abc", "owner-code")
  end

  test "an installation GitHub does not have is not bound", ctx do
    {_url, state} = begin!(ctx.owner, ctx.team)

    assert {:error, {:unprocessable, "not_your_installation", _}} =
             Connect.finish(ctx.owner, "session-a", state, "999", "owner-code")

    assert Store.installations(ctx.team.id) == []
  end

  test "somebody else's installation is refused, though it exists for the App", ctx do
    # The exploit: a workspace of one's own, a state of one's own, and a
    # victim's installation id typed into the callback. The App can read
    # installation 55; the returning person cannot see it.
    {_url, state} = begin!(ctx.owner, ctx.team)
    {:ok, %{account: "victim"}} = Ravix.GitHub.installation(ctx.app, 55)

    assert {:error, {:unprocessable, "not_your_installation", message}} =
             Connect.finish(ctx.owner, "session-a", state, "55", "owner-code")

    assert message =~ "not one you can see"
    assert Store.installations(ctx.team.id) == []
    assert Store.catalog(ctx.team.id) == []
  end

  test "a callback without GitHub's code, or with a bad one, is refused", ctx do
    {_url, state} = begin!(ctx.owner, ctx.team)

    assert {:error, {:unprocessable, "no_authorization", _}} =
             Connect.finish(ctx.owner, "session-a", state, "77", nil)

    {_url, state} = begin!(ctx.owner, ctx.team)

    assert {:error, %Ravix.GitHub.Error{status: 400}} =
             Connect.finish(ctx.owner, "session-a", state, "77", "forged-code")

    assert Store.installations(ctx.team.id) == []
  end

  test "the code's person is the proof: nothing of theirs is kept", ctx do
    {_url, state} = begin!(ctx.owner, ctx.team)
    assert {:ok, _} = Connect.finish(ctx.owner, "session-a", state, "77", "owner-code")
    # The exchanged token went nowhere: the user row is unchanged.
    assert Repo.reload!(ctx.owner).token_enc == ctx.owner.token_enc
  end

  test "workspace_of/1 answers only a well-formed workspace id", ctx do
    assert Connect.workspace_of("ws.#{ctx.team.id}.nonce") == ctx.team.id
    assert Connect.workspace_of("ws.../../evil.nonce") == nil
    assert Connect.workspace_of("ws.https:%2F%2Fevil.test.x") == nil
    assert Connect.workspace_of(nil) == nil
  end

  test "only owners and admins connect; members, strangers and the switch off are refused", ctx do
    member = insert_user()
    :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)
    admin = insert_user()
    :ok = Store.add_member(ctx.team.id, admin.id, :admin, ctx.owner.id)

    assert {:error, {:forbidden, _}} = Connect.begin(member, ctx.team.id, "s")
    assert {:error, :not_found} = Connect.begin(insert_user(), ctx.team.id, "s")
    assert {:error, :not_found} = Connect.begin(ctx.owner, "nope", "s")
    assert {:error, :not_found} = Connect.begin(ctx.owner, ctx.team.id, nil)
    assert {:ok, _} = Connect.begin(admin, ctx.team.id, "s")

    Application.put_env(:ravix, :workspace_access, false)
    assert {:error, :not_found} = Connect.begin(ctx.owner, ctx.team.id, "s")
  end

  test "somebody demoted between begin and callback cannot finish, and the state is spent", ctx do
    admin = insert_user()
    :ok = Store.add_member(ctx.team.id, admin.id, :admin, ctx.owner.id)
    {_url, state} = begin!(admin, ctx.team)
    {:ok, _} = Store.set_role(ctx.team.id, admin.id, :member, ctx.owner.id)

    assert {:error, {:forbidden, _}} =
             Connect.finish(admin, "session-a", state, "77", "owner-code")

    assert Store.installations(ctx.team.id) == []
    assert Repo.aggregate(ConnectState, :count) == 0
  end

  test "one installation may be connected to several workspaces, each its own row", ctx do
    {:ok, second} = Workspaces.create(ctx.owner, "Second")
    {_url, a} = begin!(ctx.owner, ctx.team)
    {_url, b} = begin!(ctx.owner, second)

    assert {:ok, _} = Connect.finish(ctx.owner, "session-a", a, "77", "owner-code")
    assert {:ok, _} = Connect.finish(ctx.owner, "session-a", b, "77", "owner-code")

    assert [%{installation_id: 77}] = Store.installations(ctx.team.id)
    assert [%{installation_id: 77}] = Store.installations(second.id)
    assert Repo.aggregate(CatalogRepo, :count) == 4
  end

  test "connecting a revoked installation again brings it back", ctx do
    {_url, state} = begin!(ctx.owner, ctx.team)
    assert {:ok, _} = Connect.finish(ctx.owner, "session-a", state, "77", "owner-code")
    Repo.update_all(Installation, set: [revoked_at: DateTime.utc_now(), status_reason: "gone"])

    {_url, again} = begin!(ctx.owner, ctx.team)
    assert {:ok, _} = Connect.finish(ctx.owner, "session-a", again, "77", "owner-code")
    assert [%Installation{revoked_at: nil, status_reason: nil}] = Store.installations(ctx.team.id)
  end

  test "without a GitHub App there is nothing to connect", ctx do
    stub(Ravix.Config, :github, fn -> nil end)
    assert {:error, {:unconfigured, :github}} = Connect.begin(ctx.owner, ctx.team.id, "s")
  end
end

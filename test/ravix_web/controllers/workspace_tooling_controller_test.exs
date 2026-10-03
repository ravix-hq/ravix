defmodule RavixWeb.WorkspaceToolingControllerTest do
  use RavixWeb.ConnCase, async: false
  use Mimic
  import Ravix.ToolingFixture
  alias Ravix.Tooling.OAuth
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

    user = insert_user()
    {:ok, workspace} = Workspaces.create(user, "Workspace")
    %{user: user, workspace: workspace}
  end

  test "real consent issues only requested workspace scopes and renders connected apps", c do
    scopes = ["workspaces:read", "workspaces:write"]
    {params, verifier} = request("mcp", scopes)
    page = build_conn() |> log_in_user(c.user) |> get("/oauth/authorize", params)
    assert html_response(page, 200)
    nonce = get_session(page, :tooling_authorization).nonce

    approved =
      page
      |> recycle()
      |> post("/oauth/authorize", %{"decision" => "allow", "consent_nonce" => nonce})

    code =
      approved
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("code")

    token_params =
      Map.merge(params, %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier
      })

    tokens = build_conn() |> post("/oauth/token", token_params) |> json_response(200)
    assert {:ok, principal} = OAuth.authenticate(tokens["access_token"], params["resource"])
    assert principal.grant.scopes == scopes
    assert Enum.find(OAuth.connections(c.user), &(&1.id == principal.grant.id)).scopes == scopes
    assert html_response(page |> recycle() |> get("/settings/connected-apps"), 200)

    assert "workspaces:read" in json_response(
             get(build_conn(), "/.well-known/oauth-authorization-server"),
             200
           )["scopes_supported"]
  end

  test "MCP discovery and calls enforce workspace scopes at the HTTP boundary", c do
    {_, read, _} = principal(c.user, "mcp", ["workspaces:read"])
    tools = rpc(read, "tools/list")["result"]["tools"]
    assert Enum.any?(tools, &(&1["name"] == "get_workspace"))
    refute Enum.any?(tools, &(&1["name"] == "create_workspace"))

    assert call(read, "get_workspace", %{"workspace_id" => c.workspace.id})["structuredContent"][
             "id"
           ] == c.workspace.id

    assert call(read, "update_workspace", %{
             "workspace_id" => c.workspace.id,
             "name" => "Denied",
             "request_id" => "r"
           })["isError"]

    {_, write, _} = principal(c.user, "mcp", ["workspaces:write"])

    refute call(write, "create_workspace", %{"name" => "Created", "request_id" => "create"})[
             "isError"
           ]

    assert length(Workspaces.list(c.user)) == 2
    assert call(read, "list_workspaces", %{"limit" => 101})["isError"]
    assert call(read, "get_workspace", %{"workspace_id" => 123})["isError"]
    {_, legacy, _} = principal(c.user, "mcp", ["projects:read", "projects:write"])

    refute Enum.any?(
             rpc(legacy, "tools/list")["result"]["tools"],
             &String.contains?(&1["name"], "workspace")
           )
  end

  test "other IDs, removed memberships and revoked tokens fail over HTTP", c do
    member = insert_user()
    :ok = Store.add_member(c.workspace.id, member.id, :member, c.user.id)
    {p, token, _} = principal(member, "mcp", ["workspaces:read", "workspaces:write"])
    outsider = insert_user()
    {:ok, other} = Workspaces.create(outsider, "Other")
    assert call(token, "get_workspace", %{"workspace_id" => other.id})["isError"]

    assert call(token, "update_workspace", %{
             "workspace_id" => c.workspace.id,
             "name" => "No",
             "request_id" => "no"
           })["isError"]

    :ok = Workspaces.remove_member(c.user, c.workspace.id, member.id)
    assert call(token, "get_workspace", %{"workspace_id" => c.workspace.id})["isError"]
    :ok = OAuth.disconnect(member, p.grant.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token.access_token)
      |> post("/mcp", payload("tools/list"))

    assert json_response(conn, 401)["error"] == "invalid_token"
  end

  test "GitHub connect URL requires a live browser session and mints one-time secured state", c do
    app = Ravix.WorkspaceGitHubFixture.github(%{})
    stub(Ravix.Config, :github, fn -> app end)
    {_, tokens, _} = principal(c.user, "mcp", ["workspaces:write"])

    url =
      call(tokens, "get_workspace_connect_url", %{"workspace_id" => c.workspace.id})[
        "structuredContent"
      ]["url"]

    path = URI.parse(url).path
    assert json_response(get(build_conn(), path), 401)
    other = build_conn() |> log_in_user(insert_user()) |> get(path)
    assert json_response(other, 404)
    session = build_conn() |> log_in_user(c.user)
    connected = get(session, path)

    state =
      connected
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    assert Workspaces.Connect.workspace_of(state) == c.workspace.id
    hash = session |> get_session(:session_token) |> Ravix.Crypto.sha256()
    assert {:error, :stale} = Workspaces.Connect.finish(c.user, "other-session", state, 77, nil)

    assert {:error, {:unprocessable, "no_authorization", _}} =
             Workspaces.Connect.finish(c.user, hash, state, 77, nil)

    assert {:error, :stale} = Workspaces.Connect.finish(c.user, hash, state, 77, nil)
    :ok = Ravix.Accounts.end_session(hash)
    assert json_response(session |> recycle() |> get(path), 401)
  end

  defp payload(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp rpc(token, method, params \\ %{}),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token.access_token)
      |> post("/mcp", payload(method, params))
      |> json_response(200)

  defp call(token, name, args),
    do: rpc(token, "tools/call", %{"name" => name, "arguments" => args})["result"]
end

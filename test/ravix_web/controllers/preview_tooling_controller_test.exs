defmodule RavixWeb.PreviewToolingControllerTest do
  use RavixWeb.ConnCase, async: true, group: :preview_ports
  use Mimic

  import Ravix.PreviewsFixture
  import Ravix.ToolingFixture, only: [principal: 1, principal: 3]

  alias Ravix.Sprites.Error, as: SpritesError
  alias Ravix.Tooling.{Catalog, OAuth, PreviewCatalog}

  setup do
    provider = start_provider()
    stub_provider(provider)
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project)
    {p, token, _} = principal(user)
    %{provider: provider, user: user, project: project, track: track, p: p, token: token}
  end

  test "all preview tools are discoverable and reachable through authenticated MCP", c do
    tools = request(c.token, rpc("tools/list"))["result"]["tools"]

    for tool <- PreviewCatalog.tools() do
      assert Enum.any?(
               tools,
               &(&1["name"] == tool.name and &1["inputSchema"] == tool.inputSchema)
             )
    end

    config = %{"directory" => ".", "command" => "worker"}
    defaults = %{"project_id" => c.project.id, "request_id" => "defaults", "config" => config}
    assert success(c, "update_preview_defaults", defaults)["config"]["command"] == "worker"

    assert success(c, "get_preview_defaults", %{"project_id" => c.project.id})["config"][
             "command"
           ] == "worker"

    args = %{"track_id" => c.track.id}
    assert success(c, "get_preview_config", args)["override"] == nil
    assert success(c, "preview_status", args)["state"] == "stopped"
    assert success(c, "preview_logs", args)["logs"] == ""

    assert success(
             c,
             "update_preview_config",
             Map.merge(args, %{"request_id" => "override", "config" => config})
           )["config"]["command"] == "worker"

    for name <- ~w(run_preview start_preview restart_preview stop_preview) do
      result = success(c, name, Map.put(args, "request_id", name))
      refute Map.has_key?(result, "open_url")
      await_background()
    end

    assert success(c, "preview_status", args)["state"] == "stopped"
    assert state(c.provider).creates == 2
  end

  test "scopes filter preview tools and direct calls cannot bypass them", c do
    for scope <- ~w(tracks:read tracks:write projects:write) do
      {_, token, _} = principal(c.user, "mcp", [scope])
      tools = request(token, rpc("tools/list"))["result"]["tools"]
      actual = tools |> Enum.map(& &1["name"]) |> Enum.filter(&(&1 in PreviewCatalog.names()))

      expected =
        PreviewCatalog.tools()
        |> Enum.filter(&Catalog.allowed?(&1, [scope]))
        |> Enum.map(& &1.name)

      assert actual == expected

      for tool <- PreviewCatalog.tools(), tool.name not in expected do
        result =
          request(token, rpc("tools/call", %{"name" => tool.name, "arguments" => args(c, tool)}))[
            "result"
          ]

        assert result["isError"]
        assert result["structuredContent"]["error"]["code"] == "owner_only"
      end
    end
  end

  test "schema validation refuses unbounded logs, unknown config fields, missing IDs and browser grants",
       c do
    for {name, args} <- [
          {"preview_logs", %{"track_id" => c.track.id, "limit" => 4001}},
          {"preview_logs", %{"track_id" => c.track.id, "limit" => 0}},
          {"start_preview", %{"track_id" => c.track.id}},
          {"restart_preview",
           %{"track_id" => c.track.id, "request_id" => String.duplicate("r", 101)}},
          {"update_preview_config",
           %{
             "track_id" => c.track.id,
             "request_id" => "bad",
             "config" => %{"directory" => ".", "command" => "worker", "token" => "secret"}
           }},
          {"update_preview_config", %{"track_id" => c.track.id, "request_id" => "empty"}},
          {"start_preview",
           %{"track_id" => c.track.id, "request_id" => "bad", "session_hash" => "session"}}
        ] do
      result =
        request(c.token, rpc("tools/call", %{"name" => name, "arguments" => args}))["result"]

      assert result["isError"]
      assert result["structuredContent"]["error"]["code"] == "invalid_arguments"
    end

    assert state(c.provider).creates == 0
  end

  test "out-of-scope IDs, provider failures and revoked tokens have stable HTTP errors", c do
    stranger = insert_track()

    result =
      request(
        c.token,
        rpc("tools/call", %{
          "name" => "preview_status",
          "arguments" => %{"track_id" => stranger.id}
        })
      )["result"]

    assert result["isError"]
    assert result["structuredContent"]["error"]["code"] == "not_found"

    Ravix.Previews.save_config(c.user, c.track.id, %{directory: ".", command: "worker"})
    success(c, "start_preview", %{"track_id" => c.track.id, "request_id" => "start"})
    await_background()

    stub(Ravix.Sprites, :service_logs, fn _, _, _ ->
      {:error, SpritesError.new(502, "offline")}
    end)

    result =
      request(
        c.token,
        rpc("tools/call", %{"name" => "preview_logs", "arguments" => %{"track_id" => c.track.id}})
      )["result"]

    assert result["isError"]
    assert result["structuredContent"]["error"]["code"] == "sprites_error"

    OAuth.disconnect(c.user, c.p.grant.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> c.token.access_token)
      |> post("/mcp", rpc("tools/list"))

    assert json_response(conn, 401)["error"] == "invalid_token"
  end

  defp success(c, name, args) do
    result = request(c.token, rpc("tools/call", %{"name" => name, "arguments" => args}))["result"]
    refute result["isError"], inspect(result)
    result["structuredContent"]
  end

  defp args(c, tool) do
    id =
      if String.ends_with?(tool.name, "defaults"),
        do: %{"project_id" => c.project.id},
        else: %{"track_id" => c.track.id}

    args =
      if "request_id" in tool.inputSchema["required"],
        do: Map.put(id, "request_id", tool.name),
        else: id

    if String.starts_with?(tool.name, "update_"), do: Map.put(args, "reset", true), else: args
  end

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp request(token, body),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token.access_token)
      |> post("/mcp", body)
      |> json_response(200)
end

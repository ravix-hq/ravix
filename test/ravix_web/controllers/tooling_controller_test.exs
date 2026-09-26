defmodule RavixWeb.ToolingControllerTest do
  use RavixWeb.ConnCase, async: true
  use Mimic
  alias Ravix.Fountain
  alias Ravix.Fountain.Client
  alias Ravix.PromptQueue.Store, as: QueueStore
  alias Ravix.Tooling.{OAuth, Tasks}
  import Ravix.ToolingFixture

  setup do
    user = insert_user()
    project = insert_project(user: user, runtime: "plain")
    track = insert_track(project: project, conversation_id: "conversation")
    stub(Fountain, :client, fn -> Client.new("https://fountain.test", "test-key") end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    %{user: user, project: project, track: track}
  end

  test "MCP serializes project ownership for a track-only guest", %{
    user: owner,
    project: project,
    track: track
  } do
    guest = insert_user()
    insert_track_member(track, guest)
    {_, token, _} = principal(guest)

    projects =
      json_response(request(token, "/mcp", tool("list_projects")), 200)["result"][
        "structuredContent"
      ]["items"]

    assert [%{"name" => name, "owner_login" => login}] = projects
    assert name == project.name
    assert login == owner.login

    result =
      json_response(
        request(token, "/mcp", tool("list_tracks", %{"project_id" => project.id})),
        200
      )

    assert [%{"owner_login" => ^login, "id" => id}] =
             result["result"]["structuredContent"]["items"]

    assert id == track.id
  end

  test "wait_task returns a single JSON tool result through the router", %{
    user: user,
    track: track
  } do
    {p, token, _} = principal(user)
    {:ok, task} = Tasks.send(p, track.id, "hello", "wait")

    conn =
      request(token, "/mcp", tool("wait_task", %{"task_ids" => [task.id], "timeout_ms" => 0}))

    result = Jason.decode!(conn.resp_body)["result"]
    refute result["isError"]
    assert result["structuredContent"]["changed"] == []
    assert [%{"id" => id}] = result["structuredContent"]["tasks"]
    assert id == task.id
    {_, limited, _} = principal(user, "mcp", ["tracks:write"])
    result = json_response(request(limited, "/mcp", rpc("tools/list")), 200)["result"]
    refute Enum.any?(result["tools"], &(&1["name"] == "wait_task"))
    conn = request(limited, "/mcp", tool("wait_task", %{"task_ids" => [task.id]}))
    assert Jason.decode!(conn.resp_body)["result"]["isError"]
  end

  test "MCP rejects absent tokens, other audiences and untrusted origins", %{user: user} do
    assert response = post(build_conn(), "/mcp", rpc("initialize"))
    assert json_response(response, 401)["error"] == "invalid_token"
    assert [challenge] = get_resp_header(response, "www-authenticate")
    assert challenge =~ "/.well-known/oauth-protected-resource/mcp"
    {_, token, _} = principal(user, "a2a")
    assert json_response(request(token, "/mcp", rpc("initialize")), 401)
    {_, token, _} = principal(user)

    bad_origin =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token.access_token)
      |> put_req_header("origin", "https://evil.test")
      |> post("/mcp", rpc("initialize"))

    assert response(bad_origin, 403) == "Origin not allowed"

    invalid =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token.access_token)
      |> put_req_header("mcp-protocol-version", "old")
      |> post("/mcp", rpc("initialize"))

    assert json_response(invalid, 200)["error"]["code"] == -32_600
    assert response(get(build_conn(), "/mcp"), 405)
    assert response(delete(build_conn(), "/mcp"), 405)
  end

  test "MCP initialization, discovery, notifications and tools work through the router", %{
    user: user,
    project: project
  } do
    {_, token, _} = principal(user)

    assert %{"result" => %{"protocolVersion" => "2025-11-25"}} =
             json_response(request(token, "/mcp", rpc("initialize")), 200)

    assert %{"result" => %{}} = json_response(request(token, "/mcp", rpc("ping")), 200)

    assert response(
             request(token, "/mcp", %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
             202
           ) == ""

    %{"result" => %{"tools" => tools}} =
      json_response(request(token, "/mcp", rpc("tools/list")), 200)

    assert Enum.any?(tools, &(&1["name"] == "create_track"))
    assert Enum.any?(tools, &(&1["name"] == "wait_task"))
    refute Enum.any?(tools, &Map.has_key?(&1, "scope"))
    result = json_response(request(token, "/mcp", tool("list_projects")), 200)["result"]
    refute result["isError"]
    assert [%{"id" => id}] = result["structuredContent"]["items"]
    assert id == project.id

    for payload <- [rpc("missing"), %{"method" => "ping"}, rpc("ping", [])] do
      assert json_response(request(token, "/mcp", payload), 200)["error"]
    end

    assert json_response(request(token, "/mcp", rpc("tools/call")), 200)["error"]["code"] ==
             -32_602
  end

  test "scopes filter the catalog and prevent calls even with known names", %{
    user: user,
    track: track
  } do
    {_, token, _} = principal(user, "mcp", ["tracks:read"])
    result = json_response(request(token, "/mcp", rpc("tools/list")), 200)["result"]
    refute Enum.any?(result["tools"], &(&1["name"] == "send_prompt"))
    args = %{"track_id" => track.id, "prompt" => "hello", "request_id" => "r1"}

    assert json_response(request(token, "/mcp", tool("send_prompt", args)), 200)["result"][
             "isError"
           ]

    assert json_response(request(token, "/mcp", tool("missing")), 200)["error"]["code"] == -32_602

    assert json_response(request(token, "/mcp", tool("get_track", %{"track_id" => 12})), 200)[
             "result"
           ]["isError"]

    assert json_response(
             request(
               token,
               "/mcp",
               tool("get_track", %{"track_id" => track.id, "extra" => true})
             ),
             200
           )["result"]["isError"]
  end

  test "MCP sends, polls and cancels the same durable task", %{user: user, track: track} do
    {p, token, _} = principal(user)
    params = %{"track_id" => track.id, "prompt" => "hello", "request_id" => "desktop-request"}

    result =
      json_response(request(token, "/mcp", tool("send_prompt", params)), 200)["result"][
        "structuredContent"
      ]

    assert result["contextId"] == track.id
    id = result["id"]
    assert {:ok, _} = Tasks.get(p, id)

    assert json_response(request(token, "/mcp", tool("get_task", %{"task_id" => id})), 200)[
             "result"
           ]["structuredContent"]["status"]["state"] == "TASK_STATE_SUBMITTED"

    assert json_response(request(token, "/mcp", tool("cancel_task", %{"task_id" => id})), 200)[
             "result"
           ]["structuredContent"]["status"]["state"] == "TASK_STATE_CANCELED"

    OAuth.disconnect(user, p.grant.id)
    assert json_response(request(token, "/mcp", rpc("tools/list")), 401)
  end

  test "A2A card advertises 1.0, OAuth, streaming and text-only work", %{user: user} do
    card = get(build_conn(), "/.well-known/agent-card.json") |> json_response(200)

    assert [%{"protocolVersion" => "1.0", "protocolBinding" => "JSONRPC"}] =
             card["supportedInterfaces"]

    assert card["capabilities"]["streaming"]
    refute Map.has_key?(card, "projects")
    {_, token, _} = principal(user, "a2a")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token.access_token)
      |> put_req_header("a2a-version", "0.3")
      |> post("/a2a", rpc("GetTask", %{"id" => "none"}))

    assert json_response(conn, 200)["error"]["code"] == -32_009
  end

  test "A2A submits a task and retrieves it after reconnect with an independently issued token",
       %{user: user, track: track} do
    {p, token, params} = principal(user, "a2a")
    body = send_message(track.id)
    result = json_response(request(token, "/a2a", rpc("SendMessage", body)), 200)["result"]
    id = result["task"]["id"]
    assert result["task"]["status"]["state"] == "TASK_STATE_SUBMITTED"

    assert json_response(request(token, "/a2a", rpc("SendMessage", body)), 200)["result"]["task"][
             "id"
           ] == id

    {:ok, next} =
      OAuth.exchange(%{
        "grant_type" => "refresh_token",
        "refresh_token" => token.refresh_token,
        "resource" => params["resource"],
        "client_id" => params["client_id"]
      })

    assert json_response(request(next, "/a2a", rpc("GetTask", %{"id" => id})), 200)["result"][
             "id"
           ] == id

    assert json_response(request(next, "/a2a", rpc("ListTasks")), 200)["result"]["totalSize"] == 1

    assert json_response(request(next, "/a2a", rpc("CancelTask", %{"id" => id})), 200)["result"][
             "status"
           ]["state"] == "TASK_STATE_CANCELED"

    assert json_response(request(next, "/a2a", rpc("SubscribeToTask", %{"id" => id})), 200)[
             "error"
           ]["code"] == -32_004

    assert {:ok, %{state: "TASK_STATE_CANCELED"}} = Tasks.get(p, id)
  end

  test "A2A streaming completes with the correlated result", %{user: user, track: track} do
    {p, token, _} = principal(user, "a2a")
    body = send_message(track.id)
    id = Tasks.id(p, body["message"]["messageId"])
    # Stub the provider, not task creation or state. The accepted queue row is
    # marked delivered while the stream checks it for the first time.
    stub(Fountain, :turns, fn _, _ ->
      {:ok,
       [
         Fountain.Shapes.turn(%{
           "id" => "turn",
           "client_request_id" => id,
           "status" => "completed"
         })
       ]}
    end)

    stub(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], has_more: false, next_cursor: 1}}
    end)

    {:ok, task} = Tasks.send(p, track.id, "hello", "desktop-message")
    QueueStore.mark_delivered(task.id)
    conn = request(token, "/a2a", rpc("SendStreamingMessage", body))
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.resp_body =~ "TASK_STATE_COMPLETED"
    assert conn.resp_body =~ id
  end

  test "A2A malformed and unsupported operations fail without side effects", %{
    user: user,
    track: track
  } do
    {_, token, _} = principal(user, "a2a")

    for {method, params, code} <- [
          {"Unknown", %{}, -32_601},
          {"GetTask", %{}, -32_602},
          {"GetTask", %{"id" => "unknown"}, -32_001},
          {"GetExtendedAgentCard", %{}, -32_004},
          {"CreateTaskPushNotificationConfig", %{}, -32_003},
          {"SendMessage", %{}, -32_602},
          {"SendMessage",
           put_in(send_message(track.id), ["message", "parts"], [%{"data" => %{}}]), -32_005},
          {"SendMessage", put_in(send_message(track.id), ["message", "taskId"], "old-task"),
           -32_004},
          {"SendMessage",
           put_in(send_message(track.id), ["configuration", "taskPushNotificationConfig"], %{}),
           -32_003},
          {"SendMessage",
           put_in(send_message(track.id), ["configuration", "returnImmediately"], "yes"),
           -32_602},
          {"SendMessage",
           update_in(send_message(track.id), ["message"], &Map.delete(&1, "contextId")), -32_602}
        ] do
      result = json_response(request(token, "/a2a", rpc(method, params)), 200)
      assert result["error"]["code"] == code, inspect({method, result})
    end
  end

  test "malformed protocol JSON gets a JSON-RPC parse error" do
    for path <- ["/mcp", "/a2a"] do
      conn = build_conn() |> put_req_header("content-type", "application/json") |> post(path, "{")
      assert json_response(conn, 400)["error"]["code"] == -32_700
    end
  end

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp tool(name, args \\ %{}), do: rpc("tools/call", %{"name" => name, "arguments" => args})

  defp request(token, path, body),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token.access_token)
      |> post(path, body)

  defp send_message(track),
    do: %{
      "message" => %{
        "messageId" => "desktop-message",
        "role" => "ROLE_USER",
        "contextId" => track,
        "parts" => [%{"text" => "hello"}]
      },
      "configuration" => %{"returnImmediately" => true}
    }
end

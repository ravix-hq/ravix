defmodule RavixWeb.PreviewControllerTest do
  use RavixWeb.ConnCase, async: true
  use Mimic

  alias Ravix.Previews.Agent

  test "the preview helper endpoint reaches its bearer boundary and rejects missing grants", %{
    conn: conn
  } do
    conn = post(conn, "/api/tracks/unknown/preview/agent", %{action: "status"})
    assert %{"error" => "preview_agent_auth"} = json_response(conn, 401)
  end

  test "the HTTP boundary forwards the bearer and translates the context result", %{conn: conn} do
    expect(Agent, :route, fn "track",
                             "Bearer test-token",
                             %{"track_id" => "track", "action" => "status"} ->
      {:ok, %{running: true}}
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer test-token")
      |> post("/api/tracks/track/preview/agent", %{action: "status"})

    assert %{"running" => true} = json_response(conn, 200)
  end
end

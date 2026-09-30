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

  describe "opening a preview in a new tab" do
    setup %{conn: conn} do
      user = insert_user()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "?port= opens that machine port through the context's check", %{conn: conn, user: user} do
      expect(Ravix.Previews, :open_port, fn ^user, "track", hash, 5173 ->
        assert is_binary(hash)
        {:ok, "http://t-a--p5173.preview.test/__ravix/open#ticket"}
      end)

      conn = get(conn, "/preview/track?port=5173")
      assert redirected_to(conn) == "http://t-a--p5173.preview.test/__ravix/open#ticket"
    end

    test "a port the context refuses, or that is not a number, gets no ticket", %{conn: conn} do
      expect(Ravix.Previews, :open_port, fn _, "track", _, "22x" ->
        {:error, {:unprocessable, "port", "Nothing is listening on that port yet."}}
      end)

      conn = get(conn, "/preview/track?port=22x")
      assert %{"error" => "port"} = json_response(conn, 422)
    end

    test "without a port it is the run script, as before", %{conn: conn} do
      expect(Ravix.Previews, :open, fn _, "track", _ ->
        {:ok, %{open_url: "http://t-a.preview.test/__ravix/open#run"}}
      end)

      assert redirected_to(get(conn, "/preview/track")) ==
               "http://t-a.preview.test/__ravix/open#run"
    end
  end
end

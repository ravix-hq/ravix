defmodule RavixWeb.PromptImageControllerTest do
  use RavixWeb.ConnCase, async: true

  import Mimic

  alias Ravix.Fountain.{Client, FakeTransport, Image}
  alias Ravix.Tracks.Thread

  setup :verify_on_exit!

  @png <<137, "PNG\r\n", 26, "\n", 0>>

  setup %{conn: conn} do
    stub(Ravix.Fountain, :client, fn ->
      Client.new("http://fountain.test", "test-key")
    end)

    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation-images")
    %{conn: log_in_user(conn, user), user: user, project: project, track: track}
  end

  defp image_path(track, position \\ "0", thread \\ nil, turn \\ "turn-image") do
    "/tracks/#{track.id}/threads/#{thread || track.id}/turns/#{turn}/images/#{position}"
  end

  test "serves retained bytes to an authorized reader, accepting image requests", ctx do
    client =
      FakeTransport.client([
        {%{
           method: "GET",
           path: "/api/conversations/conversation-images/turns/turn-image/images/0",
           headers: [{"accept", "image/*"}]
         }, {200, [{"content-type", "image/png"}], @png}}
      ])

    stub(Ravix.Fountain, :client, fn -> client end)
    conn = ctx.conn |> put_req_header("accept", "image/png") |> get(image_path(ctx.track))
    assert response(conn, 200) == @png
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
  end

  test "rejects another track or thread, invalid positions, and unopened tracks before provider access",
       ctx do
    stranger = insert_user()
    foreign = insert_track(project: insert_project(user: stranger), conversation_id: "foreign")
    unopened = insert_track(project: ctx.project)
    reject(&Ravix.Fountain.turn_image/4)

    for url <- [
          image_path(foreign),
          image_path(ctx.track, "0", foreign.id),
          image_path(unopened),
          image_path(ctx.track, "-1"),
          image_path(ctx.track, "6"),
          image_path(ctx.track, "bad")
        ] do
      assert ctx.conn |> get(url) |> response(404)
    end
  end

  test "requires a current session on each request", ctx do
    reject(&Ravix.Fountain.turn_image/4)
    assert build_conn() |> get(image_path(ctx.track)) |> response(401)
    token = get_session(ctx.conn, :session_token)
    Ravix.Accounts.end_session(Ravix.Crypto.sha256(token))
    assert ctx.conn |> get(image_path(ctx.track)) |> response(401)
  end

  test "track membership removal denies an already signed-in reader", ctx do
    reader = insert_user()
    membership = insert_track_member(ctx.track, reader)
    conn = log_in_user(build_conn(), reader)

    expect(Ravix.Fountain, :turn_image, fn _, "conversation-images", "turn-image", 0 ->
      Image.decode(@png)
    end)

    assert conn |> get(image_path(ctx.track)) |> response(200) == @png
    Ravix.Repo.delete!(membership)
    reject(&Ravix.Fountain.turn_image/4)
    assert conn |> get(image_path(ctx.track)) |> response(404)
  end

  test "an additional thread resolves its own conversation", ctx do
    thread =
      %Thread{}
      |> Thread.changeset(%{
        track_id: ctx.track.id,
        title: "Second",
        conversation_id: "second-conversation"
      })
      |> Ravix.Repo.insert!()

    expect(Ravix.Fountain, :turn_image, fn _, "second-conversation", "turn-image", 0 ->
      Image.decode(@png)
    end)

    assert ctx.conn |> get(image_path(ctx.track, "0", thread.id)) |> response(200) == @png
  end

  test "a foreign turn cannot be fetched through an accessible conversation", ctx do
    client =
      FakeTransport.client([
        {%{
           method: "GET",
           path: "/api/conversations/conversation-images/turns/foreign-turn/images/0"
         }, {404, [], %{error: "not_found"}}}
      ])

    stub(Ravix.Fountain, :client, fn -> client end)
    assert ctx.conn |> get(image_path(ctx.track, "0", nil, "foreign-turn")) |> response(404)
  end

  test "active content masquerading as an image is not served", ctx do
    client =
      FakeTransport.client([
        {%{
           method: "GET",
           path: "/api/conversations/conversation-images/turns/turn-image/images/0"
         }, {200, [{"content-type", "image/png"}], "<svg onload='alert(1)'/>"}}
      ])

    stub(Ravix.Fountain, :client, fn -> client end)
    assert ctx.conn |> get(image_path(ctx.track)) |> response(404)
  end
end

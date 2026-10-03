defmodule RavixWeb.RoutineWebhookControllerTest do
  use RavixWeb.ConnCase, async: true
  import Mimic
  alias Ravix.{Routines, Tracks}

  setup :verify_on_exit!

  setup do
    user = insert_user()
    project = insert_project(user: user)

    {:ok, routine, token} =
      Routines.create(user, project.id, %{name: "Triage", prompt: "Triage data"})

    %{user: user, project: project, routine: routine, token: token}
  end

  defp deliver(routine, token, body, key \\ "event") do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("idempotency-key", key)
    |> post("/api/routines/#{routine.id}/webhook", body)
  end

  test "reachable webhook queues once and exposes outcome on retry", ctx do
    track = insert_track(project: ctx.project)
    expect(Tracks, :open, fn _, _, _ -> {:ok, track} end)
    expect(Tracks, :prompt, fn _, _, _ -> {:ok, %{}} end)

    response =
      deliver(ctx.routine, ctx.token, ~s({"a":1,"nested":{"x":2,"y":3}})) |> json_response(202)

    assert response["status"] == "queued"
    assert response["track_id"] == track.id

    duplicate =
      deliver(ctx.routine, ctx.token, ~s({"nested":{"y":3,"x":2},"a":1})) |> json_response(200)

    assert duplicate["id"] == response["id"]
    assert duplicate["duplicate"]
    assert deliver(ctx.routine, ctx.token, "{}") |> json_response(409)
  end

  test "malformed, oversized and non-JSON requests are refused before track effects", ctx do
    reject(&Tracks.open/3)

    for body <- ["{", "[]", "null", "1"] do
      assert deliver(ctx.routine, ctx.token, body) |> json_response(400)
    end

    assert deliver(ctx.routine, ctx.token, Jason.encode!(%{data: String.duplicate("x", 40_000)}))
           |> json_response(413)

    assert deliver(ctx.routine, ctx.token, "{}", String.duplicate("k", 129)) |> json_response(400)

    assert build_conn()
           |> put_req_header("content-type", "text/plain")
           |> post("/api/routines/#{ctx.routine.id}/webhook", "data")
           |> json_response(415)

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/api/routines/#{ctx.routine.id}/webhook", "{}")
           |> json_response(400)

    assert {:ok, []} = Routines.history(ctx.user, ctx.routine.id)
  end

  test "paused, rotated, deleted and revoked credentials return useful errors", ctx do
    reject(&Tracks.open/3)
    assert deliver(ctx.routine, "wrong", "{}") |> json_response(401)
    {:ok, _} = Routines.update(ctx.user, ctx.routine.id, %{enabled: false})
    assert deliver(ctx.routine, ctx.token, "{}") |> json_response(403)
    {:ok, _, new_token} = Routines.rotate(ctx.user, ctx.routine.id)
    assert deliver(ctx.routine, ctx.token, "{}") |> json_response(401)
    {:ok, _} = Routines.delete(ctx.user, ctx.routine.id)
    assert deliver(ctx.routine, new_token, "{}") |> json_response(401)
  end
end

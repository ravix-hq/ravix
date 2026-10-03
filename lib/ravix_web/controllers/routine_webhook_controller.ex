defmodule RavixWeb.RoutineWebhookController do
  use RavixWeb, :controller
  alias Ravix.Routines

  def create(conn, %{"routine_id" => id}) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         [request_id] <- get_req_header(conn, "idempotency-key") do
      respond(conn, Routines.receive(id, token, request_id, conn.assigns.routine_event))
    else
      _ -> conn |> put_status(400) |> json(%{error: "bearer_and_idempotency_key_required"})
    end
  end

  defp respond(conn, {:ok, dispatch, disposition}) do
    status = if disposition == :duplicate, do: 200, else: 202

    conn
    |> put_status(status)
    |> json(%{
      id: dispatch.id,
      status: dispatch.status,
      track_id: dispatch.track_id,
      duplicate: disposition == :duplicate
    })
  end

  defp respond(conn, {:error, reason}) do
    {status, error} =
      case reason do
        :unauthorized -> {401, "invalid_or_revoked_credential"}
        :paused -> {403, "routine_paused"}
        :conflict -> {409, "idempotency_key_reused"}
        :too_large -> {413, "payload_too_large"}
        :invalid_request -> {400, "invalid_request"}
        _ -> {503, "dispatch_unavailable"}
      end

    conn |> put_status(status) |> json(%{error: error})
  end
end

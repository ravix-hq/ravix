defmodule RavixWeb.PreviewController do
  @moduledoc "Opens a fresh preview ticket for each new browser tab."
  use RavixWeb, :controller

  alias Ravix.{Crypto, Previews}
  alias RavixWeb.{Error, Plugs.CurrentUser}

  # This API uses its scoped bearer grant, never a browser cookie or CSRF token.
  def agent(conn, %{"track_id" => track_id} = body) do
    authorization = conn |> get_req_header("authorization") |> List.first()

    case Previews.Agent.route(track_id, authorization, body) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> Error.send_json(conn, Error.from(reason, noun: "track"))
    end
  end

  def open(conn, %{"track_id" => track_id}) do
    with {:ok, user} <- CurrentUser.require_user(conn),
         token when is_binary(token) <- get_session(conn, CurrentUser.session_key()),
         {:ok, %{open_url: url}} <- Previews.open(user, track_id, Crypto.sha256(token)) do
      redirect(conn, external: url)
    else
      {:error, reason} -> Error.send_json(conn, reason)
      _ -> Error.send_json(conn, :unauthenticated)
    end
  end
end

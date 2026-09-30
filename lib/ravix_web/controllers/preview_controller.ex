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

  # With `?port=`, a port on the track's machine rather than the run script;
  # `Previews.open_port/4` decides whether it is one this person may open.
  def open(conn, %{"track_id" => track_id} = params) do
    with {:ok, user} <- CurrentUser.require_user(conn),
         token when is_binary(token) <- get_session(conn, CurrentUser.session_key()),
         {:ok, url} <- open_url(user, track_id, Crypto.sha256(token), params["port"]) do
      redirect(conn, external: url)
    else
      {:error, reason} -> Error.send_json(conn, reason)
      _ -> Error.send_json(conn, :unauthenticated)
    end
  end

  defp open_url(user, track_id, session_hash, nil) do
    with {:ok, %{open_url: url}} <- Previews.open(user, track_id, session_hash), do: {:ok, url}
  end

  defp open_url(user, track_id, session_hash, port) do
    port =
      case is_binary(port) && Integer.parse(port) do
        {number, ""} -> number
        _ -> port
      end

    Previews.open_port(user, track_id, session_hash, port)
  end
end

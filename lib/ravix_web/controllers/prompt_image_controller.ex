defmodule RavixWeb.PromptImageController do
  @moduledoc "Session-authenticated access to a track's retained prompt images."
  use RavixWeb, :controller

  alias Ravix.Tracks
  alias RavixWeb.{Error, Plugs.CurrentUser}

  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"] — the provider adapter
  # checks PNG/JPEG/GIF/WebP signatures; nosniff and CSP prevent active content.
  def show(conn, %{"track" => track, "thread" => thread, "turn" => turn, "position" => value}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with {:ok, user} <- CurrentUser.require_user(conn),
         {position, ""} <- Integer.parse(value),
         {:ok, image} <- Tracks.prompt_image(user, track, thread, turn, position) do
      conn
      |> put_resp_content_type(image.media_type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> send_resp(200, image.data)
    else
      {:error, reason} -> Error.send_json(conn, reason)
      _ -> Error.send_json(conn, :not_found)
    end
  end
end

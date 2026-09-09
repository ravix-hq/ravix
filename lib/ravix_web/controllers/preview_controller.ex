defmodule RavixWeb.PreviewController do
  @moduledoc "Opens a fresh preview ticket for each new browser tab."
  use RavixWeb, :controller

  alias Ravix.{Crypto, Previews}
  alias RavixWeb.{Error, Plugs.CurrentUser}

  def open(conn, %{"track_id" => track_id}) do
    with {:ok, user} <- CurrentUser.require_user(conn),
         token when is_binary(token) <- get_session(conn, CurrentUser.session_key()),
         {:ok, %{open_url: url}} <-
           Previews.act(user, track_id, "open", %{session_hash: Crypto.sha256(token)}) do
      redirect(conn, external: url)
    else
      {:error, reason} -> Error.send_json(conn, reason)
      _ -> Error.send_json(conn, :unauthenticated)
    end
  end
end

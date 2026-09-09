defmodule RavixWeb.HealthController do
  @moduledoc "`GET /healthz`: the process is up. Render's health check reads it."
  use RavixWeb, :controller

  def show(conn, _params), do: text(conn, "ok\n")
end

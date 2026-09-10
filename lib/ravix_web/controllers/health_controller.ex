defmodule RavixWeb.HealthController do
  @moduledoc """
  Two probes that answer different questions.

  `GET /healthz` is liveness: this process is up and serving. It is deliberately
  incapable of failing for any other reason -- a restart is the only cure it
  would prescribe, and restarting an instance because the database is briefly
  away makes an outage worse.

  `GET /readyz` is readiness, and it is what Render's health check reads
  (ADR 0003). It decides whether this instance belongs in the load balancer's
  rotation, which is a question about whether it can serve a request rather than
  whether it is running: an instance that has listened but whose pool has not
  connected yet would pass `/healthz` and then fail every page it was sent.

  Readiness asks the database and nothing else. Not the cluster: a rolling
  deploy brings up an instance that has no peers yet, and one that waited for a
  sibling before joining the rotation would wait for a sibling that is waiting
  for it. Not Fountain, GitHub or Sprites either -- those are other people's
  outages, and taking every instance out of rotation during one turns a degraded
  app into no app.
  """
  use RavixWeb, :controller

  def show(conn, _params), do: text(conn, "ok\n")

  def ready(conn, _params) do
    if Ravix.Health.database?() do
      text(conn, "ok\n")
    else
      conn |> put_status(:service_unavailable) |> text("database unavailable\n")
    end
  end
end

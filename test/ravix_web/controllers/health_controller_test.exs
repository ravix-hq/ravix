defmodule RavixWeb.HealthControllerTest do
  @moduledoc """
  Both probes at the request boundary: Render reads these over HTTP, so a route
  that stopped resolving would take every instance out of rotation without a
  single context test noticing.
  """
  use RavixWeb.ConnCase, async: true
  use Mimic

  describe "GET /healthz" do
    test "says the process is up", %{conn: conn} do
      conn = get(conn, "/healthz")

      assert response(conn, 200) =~ "ok"
    end

    test "does not depend on the database, so a database outage never restarts an instance",
         %{conn: conn} do
      stub(Ravix.Health, :database?, fn -> false end)

      conn = get(conn, "/healthz")

      assert response(conn, 200) =~ "ok"
    end
  end

  describe "GET /readyz" do
    test "is ready when the database answers", %{conn: conn} do
      conn = get(conn, "/readyz")

      assert response(conn, 200) =~ "ok"
    end

    test "is not ready when the database does not, so the instance leaves the rotation",
         %{conn: conn} do
      stub(Ravix.Health, :database?, fn -> false end)

      conn = get(conn, "/readyz")

      assert response(conn, 503) =~ "database unavailable"
    end
  end
end

defmodule RavixWeb.Tooling.Wait do
  @moduledoc "One JSON response with whitespace heartbeats so closed clients release their waiter."
  import Plug.Conn
  alias RavixWeb.Tooling.{MCP, RPC}

  def call(conn, principal, params) do
    task =
      Task.Supervisor.async_nolink(Ravix.TaskSupervisor, fn -> MCP.call(principal, params) end)

    try do
      conn =
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-store")
        |> send_chunked(200)

      reply(conn, task, params["id"])
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp reply(conn, task, id) do
    case Task.yield(task, 500) do
      {:ok, {:ok, result}} ->
        emit(conn, RPC.result(id, result))

      {:ok, {:error, code, message}} ->
        emit(conn, RPC.error(id, code, message))

      {:exit, _} ->
        emit(conn, RPC.error(id, -32_603, "Wait failed"))

      nil ->
        case chunk(conn, " ") do
          {:ok, conn} -> reply(conn, task, id)
          {:error, _} -> conn
        end
    end
  end

  defp emit(conn, value) do
    case chunk(conn, Jason.encode!(value)) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end
end

defmodule RavixWeb.Plugs.RoutineBody do
  @moduledoc "Read only bounded webhook JSON, before Phoenix's general body parser."
  import Plug.Conn
  alias Ravix.Routines.Runner

  def call(conn) do
    case get_req_header(conn, "content-type") do
      ["application/json" <> _] -> read(conn)
      _ -> error(conn, 415, "json_required")
    end
  end

  defp read(conn) do
    case read_body(conn, length: Runner.max_event_bytes(), read_length: 32_769) do
      {:ok, body, conn} -> decode(conn, body)
      {:more, _body, conn} -> error(conn, 413, "payload_too_large")
      {:error, _} -> error(conn, 400, "unreadable_body")
    end
  end

  defp decode(conn, body) do
    if byte_size(body) > Runner.max_event_bytes() do
      error(conn, 413, "payload_too_large")
    else
      case Jason.decode(body) do
        {:ok, event} when is_map(event) -> assign(conn, :routine_event, event)
        _ -> error(conn, 400, "json_object_required")
      end
    end
  end

  defp error(conn, status, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: reason}))
    |> halt()
  end
end

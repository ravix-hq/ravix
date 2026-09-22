defmodule RavixWeb.ToolingController do
  @moduledoc "Authenticated stateless MCP and A2A JSON-RPC HTTP boundaries."
  use RavixWeb, :controller
  alias Ravix.Tooling.OAuth
  alias RavixWeb.Tooling.{A2A, MCP, RPC, Stream}

  def card(conn, _),
    do: conn |> put_resp_header("cache-control", "public, max-age=300") |> json(A2A.card())

  def unsupported(conn, _),
    do: conn |> put_resp_header("allow", "POST") |> send_resp(405, "Method not allowed")

  def end_session(conn, params), do: unsupported(conn, params)
  def mcp(conn, params), do: dispatch(conn, params, "mcp")
  def a2a(conn, params), do: dispatch(conn, params, "a2a")

  defp dispatch(conn, params, protocol) do
    with :ok <- origin(conn),
         {:ok, principal} <- authenticate(conn, protocol),
         :ok <- version(conn, protocol),
         :ok <- RPC.validate(params) do
      result =
        if protocol == "mcp", do: MCP.call(principal, params), else: A2A.call(principal, params)

      respond(conn, params, principal, result)
    else
      {:error, :unauthenticated} -> unauthorized(conn, protocol)
      {:error, :origin} -> send_resp(conn, 403, "Origin not allowed")
      {:error, code, message} -> json(conn, RPC.error(params["id"], code, message))
    end
  end

  defp respond(conn, _params, _principal, :notification), do: send_resp(conn, 202, "")

  defp respond(conn, params, principal, {:stream, task}),
    do: Stream.start(conn, params["id"], principal, task)

  defp respond(conn, params, principal, {:wait, task}),
    do: Stream.wait(conn, params["id"], principal, task)

  defp respond(conn, params, _principal, {:ok, result}),
    do: json(conn, RPC.result(params["id"], result))

  defp respond(conn, params, _principal, {:error, code, message}),
    do: json(conn, RPC.error(params["id"], code, message))

  defp authenticate(conn, protocol) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> OAuth.authenticate(token, OAuth.resource(protocol))
      _ -> {:error, :unauthenticated}
    end
  end

  defp unauthorized(conn, protocol) do
    metadata = Ravix.Config.public_url() <> "/.well-known/oauth-protected-resource/" <> protocol

    conn
    |> put_resp_header("www-authenticate", "Bearer resource_metadata=\"#{metadata}\"")
    |> put_status(401)
    |> json(%{error: "invalid_token"})
  end

  defp origin(conn) do
    case get_req_header(conn, "origin") do
      [] -> :ok
      [value] -> if value == Ravix.Config.public_url(), do: :ok, else: {:error, :origin}
      _ -> {:error, :origin}
    end
  end

  defp version(conn, "mcp") do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> :ok
      [version] when version in ["2025-03-26", "2025-06-18", "2025-11-25"] -> :ok
      _ -> {:error, -32_600, "Unsupported MCP protocol version"}
    end
  end

  defp version(conn, "a2a") do
    case get_req_header(conn, "a2a-version") do
      [] -> :ok
      ["1.0"] -> :ok
      _ -> {:error, -32_009, "Unsupported A2A version; use 1.0"}
    end
  end
end

defmodule RavixWeb.Tooling.RPC do
  @moduledoc "JSON-RPC envelopes shared by the protocol adapters."
  def validate(%{"jsonrpc" => "2.0", "method" => method} = request) when is_binary(method) do
    if valid_id?(request["id"]) and is_map(Map.get(request, "params", %{})),
      do: :ok,
      else: {:error, -32_600, "Invalid request"}
  end

  def validate(_), do: {:error, -32_600, "Invalid request"}
  def result(id, value), do: %{jsonrpc: "2.0", id: id, result: value}

  def error(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp valid_id?(id), do: is_nil(id) or is_integer(id) or is_binary(id)
end

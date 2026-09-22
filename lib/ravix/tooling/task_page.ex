defmodule Ravix.Tooling.TaskPage do
  @moduledoc "Validated A2A task filters and stable timestamp/ID continuation cursors."
  def parse(params) do
    limit = Map.get(params, "pageSize", 50)

    with true <- is_integer(limit) and limit in 1..100,
         true <- optional_string?(params["contextId"]),
         true <- optional_string?(params["status"]),
         true <- params["includeArtifacts"] in [nil, true, false],
         true <- history?(params["historyLength"]),
         {:ok, since} <- timestamp(params["statusTimestampAfter"]),
         {:ok, cursor} <- decode(params["pageToken"]) do
      {:ok,
       %{
         limit: limit,
         context: params["contextId"],
         status: params["status"],
         artifacts: params["includeArtifacts"] == true,
         since: since,
         cursor: cursor
       }}
    else
      _ -> {:error, {:unprocessable, "invalid_page", "Invalid task pagination parameters."}}
    end
  end

  def cursor(task),
    do: Base.url_encode64(DateTime.to_iso8601(task.updated_at) <> "|" <> task.id, padding: false)

  defp decode(value) when value in [nil, ""], do: {:ok, nil}

  defp decode(value) when is_binary(value) and byte_size(value) <= 256 do
    with {:ok, raw} <- Base.url_decode64(value, padding: false),
         [at, id] <- String.split(raw, "|", parts: 2),
         {:ok, date} <- timestamp(at),
         true <- byte_size(id) in 1..100 do
      {:ok, {date, id}}
    else
      _ -> :error
    end
  end

  defp decode(_), do: :error
  defp timestamp(nil), do: {:ok, nil}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, 0} -> {:ok, at}
      _ -> :error
    end
  end

  defp timestamp(_), do: :error
  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value) and byte_size(value) in 1..200
  defp history?(nil), do: true
  defp history?(value), do: is_integer(value) and value >= 0
end

defmodule RavixWeb.PreviewPresentation do
  @moduledoc "Readable, bounded preview diagnostics shared by the panel and gateway."

  @limit 32_000

  def loading_label(:waking, _config), do: "Waking this track's machine…"
  def loading_label(_state, config), do: loading_label(config)

  def loading_label(config) do
    case Map.get(config || %{}, :readiness_path) do
      nil -> "Starting the process…"
      path -> "Starting the app… Waiting for it to answer on #{path}."
    end
  end

  def logs(text) when is_binary(text) do
    text
    |> tail()
    |> String.split("\n")
    |> Enum.map_join("\n", &line/1)
    |> tail()
  end

  def logs(_), do: ""

  defp line(raw) do
    case Jason.decode(raw) do
      {:ok, %{"type" => stream, "data" => text}}
      when stream in ["stdout", "stderr"] and is_binary(text) ->
        "[#{stream}] " <> String.trim_trailing(text, "\n")

      {:ok, %{"message" => message} = event} when is_binary(message) ->
        case event["stream"] do
          stream when stream in ["stdout", "stderr"] -> "[#{stream}] " <> message
          _ -> message
        end

      {:ok, %{"type" => "started"}} ->
        "Service started."

      {:ok, %{"type" => "complete"}} ->
        "Service startup request completed."

      _ ->
        raw
    end
  end

  defp tail(text) when byte_size(text) <= @limit, do: text
  defp tail(text), do: text |> binary_part(byte_size(text) - @limit, @limit) |> trim_utf8()

  defp trim_utf8(<<byte, rest::binary>>) when byte >= 0x80 and byte < 0xC0, do: trim_utf8(rest)
  defp trim_utf8(text), do: text
end

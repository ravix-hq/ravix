defmodule Ravix.Previews.Stop do
  @moduledoc "Stops the applied run script, then its managed service process group."

  alias Ravix.Previews.{Config, Row, Server}
  alias Ravix.Sprites
  alias Ravix.Sprites.Shapes

  @doc "Custom shutdown is bounded; even a failing shutdown command cannot skip service stop."
  @spec service(Sprites.config(), Row.t()) :: {:ok, String.t()} | {:error, term()}
  def service(cfg, row) do
    custom = custom_stop(cfg, row, Row.applied(row))
    stopped = Sprites.service_action(cfg, row.sprite, row.service, :stop)

    case stopped do
      {:ok, _} -> output(custom)
      {:error, _} -> stopped
    end
  end

  defp output({:ok, output}), do: {:ok, output}

  defp output({:error, reason}),
    do: {:ok, "[warning] Stop command: #{Server.message_of(reason)}\n"}

  defp custom_stop(cfg, row, %Config{stop_command: command}) when is_binary(command) do
    with {:ok, service} <- Sprites.service(cfg, row.sprite, row.service) do
      if Shapes.running?(service), do: execute(cfg, row, service.dir, command), else: {:ok, ""}
    end
  end

  defp custom_stop(_cfg, _row, _config), do: {:ok, ""}

  defp execute(cfg, row, directory, command) when is_binary(directory) do
    script =
      "cd #{Sprites.shq(directory)} && " <>
        "export PORT=#{Sprites.shq(Integer.to_string(row.port))} HOST=127.0.0.1 && " <>
        "sh -lc #{Sprites.shq(command)}"

    case Sprites.exec(cfg, row.sprite, ["sh", "-lc", script], 15) do
      {:ok, %{code: 0, stdout: output}} ->
        {:ok, output}

      {:ok, %{code: code}} ->
        {:error,
         {:unavailable, "Stop command exited with status #{code}. The service was stopped."}}

      {:error, _} = error ->
        error
    end
  end

  defp execute(_cfg, _row, _directory, _command),
    do:
      {:error,
       {:unavailable, "The service directory is missing; its stop command could not run."}}
end

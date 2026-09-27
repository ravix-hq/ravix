defmodule Ravix.AgentOutageFixture do
  @moduledoc "ACP wire replay reconstructed from the reported five-retry Codex outage; no production secrets."

  def events(turn_id \\ "mine") do
    path = Path.expand("../fixtures/acp/codex_provider_timeout.jsonl", __DIR__)

    frames =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.with_index(2)
      |> Enum.map(fn {data, id} ->
        %{"id" => id, "turn_id" => turn_id, "kind" => "output", "stream" => "acp", "data" => data}
      end)

    [stage(1, turn_id, "started") | frames] ++ [stage(8, turn_id, "completed")]
  end

  defp stage(id, turn_id, state),
    do: %{
      "id" => id,
      "turn_id" => turn_id,
      "kind" => "stage",
      "stage" => "turn",
      "state" => state
    }
end

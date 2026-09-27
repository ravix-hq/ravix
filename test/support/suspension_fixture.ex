defmodule Ravix.SuspensionFixture do
  @moduledoc "Replay of the reported idle suspension; no synthetic turn-done event."

  def message,
    do:
      "The machine went to sleep during this turn (idle for 60 minutes). Send another message to continue."

  def events(turn_id \\ "sleeping") do
    [
      %{
        "id" => 1,
        "turn_id" => turn_id,
        "kind" => "stage",
        "stage" => "turn",
        "state" => "started"
      },
      %{
        "id" => 2,
        "turn_id" => turn_id,
        "kind" => "output",
        "stream" => "stdout",
        "data" => "Chromium tests are starting…"
      },
      %{
        "id" => 3,
        "turn_id" => nil,
        "kind" => "stage",
        "stage" => "sandbox",
        "state" => "done",
        "data" =>
          Jason.encode!(%{
            event: "suspended",
            reason: "idle",
            message: "Sandbox suspended after 60 minutes idle…"
          })
      }
    ]
  end
end

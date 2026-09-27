defmodule Ravix.PromptQueue.Activity do
  @moduledoc "A delivered prompt stays outstanding until its correlated turn settles."
  alias Ravix.Fountain

  def state(_client, _conversation_id, nil), do: nil

  def state(client, conversation_id, request_id) do
    case Fountain.turns(client, conversation_id) do
      {:ok, turns} ->
        case Enum.find(turns, &(&1.client_request_id == request_id)) do
          nil ->
            :pending

          %{status: status}
          when status in ["completed", "ended", "done", "cancelled", "canceled", "interrupted"] ->
            :idle

          %{status: "failed"} ->
            :failed

          %{status: "running"} ->
            :running

          _ ->
            :pending
        end

      {:error, _} ->
        :unavailable
    end
  end
end

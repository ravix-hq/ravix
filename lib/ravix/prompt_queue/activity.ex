defmodule Ravix.PromptQueue.Activity do
  @moduledoc "A delivered prompt stays outstanding until its correlated turn settles."
  alias Ravix.Fountain
  alias Ravix.Projects.Project

  @pending_window_seconds 120

  def guest?(%{sandbox_layout: :dedicated}, project, thread),
    do: is_binary(thread.runtime) and thread.runtime != Project.home_runtime(project)

  def guest?(_track, _project, _thread), do: false

  def state(_client, _conversation_id, nil), do: nil

  def state(client, conversation_id, %{id: request_id} = receipt) do
    case Fountain.turns(client, conversation_id) do
      {:ok, turns} ->
        case Enum.find(turns, &(&1.client_request_id == request_id)) do
          nil ->
            pending(receipt)

          %{status: status}
          when status in ["completed", "ended", "done", "cancelled", "canceled", "interrupted"] ->
            :idle

          %{status: "failed"} ->
            :failed

          %{status: "running"} ->
            :running

          _ ->
            pending(receipt)
        end

      {:error, _} ->
        :unavailable
    end
  end

  defp pending(%{delivered_at: %DateTime{} = at}) do
    if DateTime.diff(DateTime.utc_now(), at) < @pending_window_seconds,
      do: :pending,
      else: :expired
  end

  defp pending(_receipt), do: :expired
end

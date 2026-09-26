defmodule Ravix.PromptQueue.Recovery do
  @moduledoc """
  Context replay on the next queued prompt after a session reset.

  The queue's database claim serializes delivery per thread. A prepared reset
  remains on that prompt through ambiguous delivery; only a sent row counts as
  a receipt. Confirmation of an uncertain POST therefore commits the same
  receipt as a successful POST, including when another instance confirms it.
  """

  alias Ravix.Fountain
  alias Ravix.PromptQueue.{Item, Store}
  alias Ravix.Spec
  alias Ravix.Tracks.Track

  @doc "Read reset events and persist the context attached to this claimed delivery."
  @spec prepare(Fountain.Client.t(), Item.t(), Track.t()) ::
          {:ok, String.t()} | {:error, :context_unavailable}
  def prepare(client, row, track) do
    case Fountain.events(client, track.conversation_id) do
      {:ok, events} -> prepare_events(events, row, track)
      {:error, _reason} -> {:error, :context_unavailable}
    end
  end

  defp prepare_events(events, row, track) do
    last = Store.delivered_reset(row.thread_id)
    reset = events |> Enum.filter(&reset?/1) |> Enum.map(& &1["id"]) |> Enum.max(fn -> 0 end)

    if reset > last do
      # ownership: Server.access/1 established Access.thread_access for the
      # queued sender; only that track's assigned plan items belong in replay.
      items = Ravix.Plans.Store.for_track(track.id)
      preamble = Spec.session_recovery_prompt(track, items)
      Store.prepare_reset(row.id, reset)
      {:ok, preamble}
    else
      Store.prepare_reset(row.id, nil)
      {:ok, ""}
    end
  end

  defp reset?(%{"kind" => "stage", "id" => id, "data" => data})
       when is_integer(id) and is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"reason" => "session_gone"}} -> true
      _ -> false
    end
  end

  defp reset?(_event), do: false
end

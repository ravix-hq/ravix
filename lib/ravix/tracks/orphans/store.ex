defmodule Ravix.Tracks.Orphans.Store do
  @moduledoc "Private-track cleanup after the owner-scoped orphan maintenance door."
  import Ecto.Query
  require Logger
  alias Ravix.Repo
  alias Ravix.Tracks.{Track, TrackMember}

  def count(project_id), do: Repo.aggregate(orphaned(project_id), :count)

  @doc """
  Close every orphaned private track of a project, answering only how many.

  The count is all the owner learns: which tracks they were, who was on them
  and what they were called stay private through the close, which is the point
  of a blind cleanup. A machine that refuses is a tagged error rather than a
  crash, and refuses the whole batch: see `request_close/1`.
  """
  @spec close(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def close(project_id) do
    case Repo.transaction(fn -> close_locked(project_id) end) do
      {:ok, ids} ->
        # Announced after the commit: a page told to re-read before the rows
        # are visible re-reads exactly the state the close replaced.
        #
        # ownership: no door on this path and none needed --- the ids are the
        # tracks this function just closed, and telling their pages to re-read
        # decides nothing about who may read them. Access.project_of/2
        # admitted the owner whose button this is.
        Ravix.PromptQueue.Store.publish_queues(ids)
        Ravix.Hub.publish(project_id, :tracks)
        {:ok, length(ids)}

      {:error, reason} ->
        Logger.warning("ravix: orphan close refused on #{project_id}: #{inspect(reason)}")

        {:error,
         {:unavailable, "orphan_close_failed",
          "Those private tracks could not be closed just now. Try again in a moment."}}
    end
  end

  defp close_locked(project_id) do
    tracks = Repo.all(from t in orphaned(project_id), order_by: t.id, lock: "FOR UPDATE")
    ids = Enum.map(tracks, & &1.id)
    Enum.each(tracks, &request_close/1)

    # ownership: Access.project_of authorized orphan-only cancellation and
    # grant revocation. One statement each, for every track in the batch at
    # once, inside the transaction that already holds their rows locked.
    Ravix.PromptQueue.Store.cancel_tracks(ids)
    Ravix.Previews.Store.revoke_tracks(ids)
    Ravix.Previews.Store.revoke_agent_tracks(ids)
    ids
  end

  # A refusal is the whole batch's refusal, rolled back to the savepoint this
  # transaction opened. What was here before was a match on `{:ok, :ok}`, which
  # turned "that machine is already closing" into a crash inside the owner's
  # settings dialog, and left the tracks earlier in the batch closing.
  #
  # ownership: Access.project_of established project ownership; the locked
  # orphan predicate permits only durable machine deletion.
  defp request_close(track) do
    case Ravix.Tracks.Sandbox.Store.request_close(track) do
      {:ok, :ok} -> :ok
      other -> Repo.rollback({:close_refused, other})
    end
  end

  defp orphaned(project_id) do
    from t in Track,
      as: :track,
      where: t.project_id == ^project_id and t.visibility == :private and is_nil(t.closed_at),
      where: is_nil(t.sandbox_state) or t.sandbox_state not in [:closing, :terminated],
      where: is_nil(t.created_by) or not is_nil(t.creator_revoked_at),
      where: not exists(from m in TrackMember, where: m.track_id == parent_as(:track).id)
  end
end

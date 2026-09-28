defmodule Ravix.Tracks.Orphans.Store do
  @moduledoc "Private-track cleanup after the owner-scoped orphan maintenance door."
  import Ecto.Query
  alias Ravix.Repo
  alias Ravix.Tracks.{Track, TrackMember}

  def count(project_id), do: Repo.aggregate(orphaned(project_id), :count)

  def close(project_id) do
    # ownership: Access.project_of authorized orphan-only deletion and grant cancellation.
    result =
      Repo.transaction(fn ->
        tracks = Repo.all(from t in orphaned(project_id), order_by: t.id, lock: "FOR UPDATE")

        Enum.each(tracks, fn track ->
          # ownership: Access.project_of established project ownership;
          # the locked orphan predicate permits only durable machine deletion.
          {:ok, :ok} = Ravix.Tracks.Sandbox.Store.request_close(track)
          Ravix.PromptQueue.Store.cancel_track(track.id)
          Ravix.Previews.Store.revoke(track.id)
          Ravix.Previews.Store.revoke_agent(track.id)
        end)

        length(tracks)
      end)

    Ravix.Hub.publish(project_id, :tracks)
    result
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

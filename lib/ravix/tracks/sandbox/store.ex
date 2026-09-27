defmodule Ravix.Tracks.Sandbox.Store do
  @moduledoc """
  Unscoped persistence primitives for the future dedicated lifecycle writer.
  Nothing calls these from open/close/rebuild yet. The caller must establish
  track access before starting intent. No provider effects run here.

  A new intent advances the track generation atomically with its operation.
  Progress on old operations is retained for cleanup but cannot mutate the
  track. B7 supplies leases, reconciliation and provider idempotency before
  activating writers; revision fencing alone does not authorize side effects.
  """
  import Ecto.Query
  alias Ravix.Repo
  alias Ravix.Tracks.Sandbox.Operation
  alias Ravix.Tracks.Track

  @states %{open: :provisioning, close: :closing, rebuild: :provisioning}

  @doc "Advance only the expected dedicated generation and persist intent in the same transaction."
  def begin_operation(track_id, generation, action) when action in [:open, :close, :rebuild] do
    Repo.transaction(fn ->
      track = current_track!(track_id, generation)
      next = generation + 1

      track
      |> Track.changeset(%{sandbox_generation: next, sandbox_state: Map.fetch!(@states, action)})
      |> save!()

      %Operation{}
      |> Operation.changeset(%{
        track_id: track_id,
        generation: next,
        action: action,
        resource_ids: %{"sandbox_id" => track.sandbox_id, "vault_id" => track.vault_id}
      })
      |> save!()
    end)
  end

  @doc "A late provider result cannot replace a newer generation's ownership."
  def update_sandbox(track_id, generation, attrs) do
    Repo.transaction(fn ->
      track = current_track!(track_id, generation)

      track
      |> Track.changeset(Map.take(attrs, [:sandbox_id, :sandbox_state, :vault_id]))
      |> save!()
    end)
  end

  @doc "Historical intent, including pending cleanup from replaced generations."
  def operations(track_id) do
    Repo.all(from(o in Operation, where: o.track_id == ^track_id, order_by: [asc: o.generation]))
  end

  @doc "Progress is revision-fenced, independently of the current track generation."
  def update_operation(%Operation{} = operation, attrs) do
    operation
    |> Operation.progress_changeset(attrs)
    |> Repo.update(stale_error_field: :revision)
  end

  defp current_track!(id, generation) do
    case Repo.one(from(t in Track, where: t.id == ^id, lock: "FOR UPDATE")) do
      %Track{sandbox_layout: :dedicated, sandbox_generation: ^generation} = track -> track
      _ -> Repo.rollback(:stale_generation)
    end
  end

  defp save!(changeset) do
    case Repo.insert_or_update(changeset) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end

defmodule Ravix.Plans.Store do
  @moduledoc "Row access behind Plans' project and item access doors."
  import Ecto.Query
  alias Ravix.Plans.{Item, Plan}
  alias Ravix.Repo

  def get(id) when is_binary(id), do: Repo.get(Plan, id)
  def get(_), do: nil
  def item(id) when is_binary(id), do: Repo.get(Item, id)
  def item(_), do: nil

  def list(project_id),
    do:
      Repo.all(
        from p in Plan, where: p.project_id == ^project_id, order_by: [desc: p.inserted_at]
      )

  def items(plan_id),
    do:
      Repo.all(
        from i in Item, where: i.plan_id == ^plan_id, order_by: [asc: i.position, asc: i.id]
      )
      |> Repo.preload(:notes)

  def for_track(track_id),
    do: Repo.all(from i in Item, where: i.track_id == ^track_id) |> Repo.preload(:notes)

  def lock(id), do: Repo.one(from p in Plan, where: p.id == ^id, lock: "FOR UPDATE")
  def transaction(fun), do: Repo.transaction(fun)
  def rollback(reason), do: Repo.rollback(reason)
  def insert(changeset), do: Repo.insert(changeset)
  def update(changeset), do: Repo.update(changeset)
  def delete(row), do: Repo.delete(row)

  # ownership: Plans established Access.project_access before loading its assigned
  # tracks, including closed ones which project members must still see in history.
  def tracks(ids), do: Repo.all(from t in Ravix.Tracks.Track, where: t.id in ^ids)
end

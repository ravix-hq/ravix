defmodule Ravix.Tooling.Store do
  @moduledoc "Persistence for OAuth grants, mutation receipts and delegated tasks. Callers establish access."
  import Ecto.Query
  alias Ravix.Repo
  alias Ravix.Tooling.{Client, Credential, Grant, Receipt, Task}

  def client(id) when is_binary(id), do: Repo.get(Client, id)
  def client(_), do: nil
  def insert(row), do: Repo.insert!(row)
  def update(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()
  def transaction(fun), do: Repo.transaction(fun)
  def rollback(reason), do: Repo.rollback(reason)
  def grant(id), do: Repo.get(Grant, id)
  def lock_grant(id), do: Repo.one(from g in Grant, where: g.id == ^id, lock: "FOR UPDATE")
  def credential(hash), do: Repo.get(Credential, hash)

  def grants(user),
    do: Repo.all(from g in Grant, where: g.user_id == ^user, order_by: [desc: g.inserted_at])

  def revoke(id) do
    Repo.update_all(from(g in Grant, where: g.id == ^id), set: [revoked_at: DateTime.utc_now()])
    :ok
  end

  def claim_receipt(row) do
    now = DateTime.utc_now()

    attrs =
      row
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.merge(%{inserted_at: now, updated_at: now})

    {count, _} = Repo.insert_all(Receipt, [attrs], on_conflict: :nothing)
    {if(count == 1, do: :new, else: :existing), Repo.get!(Receipt, row.id)}
  end

  def receipt(id), do: Repo.get(Receipt, id)
  def task(id), do: Repo.get(Task, id)
  def lock_task(id), do: Repo.one(from t in Task, where: t.id == ^id, lock: "FOR UPDATE")

  # ownership: no door before this one -- the query establishes the same
  # owner/project/track membership door as Access.track_access, before paging.
  # Tasks.list additionally checks Access on every returned row.
  def tasks(user_id, client_id, opts) do
    query = visible_tasks(user_id, client_id)
    paginate_tasks(query, opts)
  end

  defp visible_tasks(user_id, client_id) do
    from task in Task,
      join: track in Ravix.Tracks.Track,
      on: track.id == task.track_id,
      join: project in Ravix.Projects.Project,
      on: project.id == track.project_id,
      left_join: tm in Ravix.Tracks.TrackMember,
      on: tm.track_id == track.id and tm.user_id == ^user_id,
      left_join: pm in Ravix.Projects.ProjectMember,
      on: pm.project_id == project.id and pm.user_id == ^user_id,
      where:
        task.user_id == ^user_id and task.client_id == ^client_id and
          is_nil(project.archived_at),
      where:
        project.user_id == ^user_id or
          (is_nil(track.closed_at) and (not is_nil(tm.user_id) or not is_nil(pm.user_id)))
  end

  defp paginate_tasks(query, opts) do
    query = filter_tasks(query, opts)
    total = Repo.aggregate(query, :count)

    page =
      case opts.cursor do
        nil ->
          query

        {at, id} ->
          from t in query, where: t.updated_at < ^at or (t.updated_at == ^at and t.id < ^id)
      end

    rows =
      Repo.all(
        from t in page, order_by: [desc: t.updated_at, desc: t.id], limit: ^(opts.limit + 1)
      )

    {rows, total}
  end

  defp filter_tasks(query, opts) do
    query = if opts.context, do: from(t in query, where: t.track_id == ^opts.context), else: query
    query = if opts.status, do: from(t in query, where: t.state == ^opts.status), else: query
    if opts.since, do: from(t in query, where: t.updated_at >= ^opts.since), else: query
  end
end

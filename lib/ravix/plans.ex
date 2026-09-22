defmodule Ravix.Plans do
  @moduledoc "Project-scoped plans. A track invitation exposes assigned items only."
  alias Ravix.Accounts.Access
  alias Ravix.Plans.{Graph, Item, Note, Plan, Status, Store}

  def create(user, project_id, attrs, actor \\ :person) do
    with {:ok, _} <- Access.project_access(user, project_id),
         {:ok, track_id} <- actor_track(user, project_id, actor) do
      Store.transaction(fn ->
        plan =
          save(
            Store.insert(
              Plan.changeset(
                %Plan{
                  project_id: project_id,
                  created_by_login: user.login,
                  created_by_track_id: track_id
                },
                attrs
              )
            )
          )

        replace_items(plan, Map.get(attrs, "items", []))
        plan
      end)
    end
  end

  def list(user, project_id) do
    with {:ok, _} <- Access.project_access(user, project_id), do: {:ok, Store.list(project_id)}
  end

  def access(user, id) do
    with %Plan{} = plan <- Store.get(id),
         {:ok, access} <- Access.project_access(user, plan.project_id) do
      {:ok, plan, access.project}
    else
      _ -> {:error, :not_found}
    end
  end

  def get(user, id) do
    with {:ok, plan, project} <- access(user, id) do
      items = Store.items(plan.id)
      {:ok, %{plan: plan, items: Status.items(project, items)}}
    end
  end

  @doc "No summary, sibling IDs, dependency IDs or other plan metadata crosses this door."
  def track_items(user, track_id) do
    with {:ok, _} <- Access.track_access(user, track_id) do
      {:ok, Enum.map(Store.for_track(track_id), &public_item(&1, false))}
    end
  end

  def update(user, id, expected_version, attrs, actor \\ :person) do
    with {:ok, plan, _} <- access(user, id),
         {:ok, _} <- actor_track(user, plan.project_id, actor) do
      Store.transaction(fn ->
        current = Store.lock(id)

        if current.version != expected_version,
          do:
            Store.rollback(
              {:conflict, "stale_version", "This plan changed. Reload before editing."}
            )

        if Map.has_key?(attrs, "items"), do: replace_items(current, attrs["items"])

        current
        |> Plan.changeset(attrs)
        |> Ecto.Changeset.put_change(:version, current.version + 1)
        |> Store.update()
        |> save()
      end)
    end
  end

  def note(user, item_id, body, actor \\ :person) do
    with {:ok, item, plan} <- item_access(user, item_id),
         {:ok, track_id} <- actor_track(user, plan.project_id, actor) do
      %Note{item_id: item.id, created_by_login: user.login, created_by_track_id: track_id}
      |> Note.changeset(%{"body" => body})
      |> Store.insert()
    end
  end

  def item_access(user, id) do
    with %Item{} = item <- Store.item(id), %Plan{} = plan <- Store.get(item.plan_id) do
      case Access.project_access(user, plan.project_id) do
        {:ok, _} -> {:ok, item, plan}
        _ -> guest_item(user, item, plan)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp guest_item(user, %{track_id: id} = item, plan) when is_binary(id) do
    with {:ok, _} <- Access.track_access(user, id), do: {:ok, item, plan}
  end

  defp guest_item(_, _, _), do: {:error, :not_found}

  # The caller supplies an authenticated actor, never a field from tool arguments.
  # Future per-track credentials resolve here; assignment separately refuses agents.
  defp actor_track(_, _, :person), do: {:ok, nil}

  defp actor_track(user, project_id, {:track_agent, track_id}) do
    with {:ok, %{track: %{project_id: ^project_id}}} <- Access.track_access(user, track_id),
         do: {:ok, track_id},
         else: (_ -> {:error, :not_found})
  end

  def public_plan(plan),
    do:
      Map.take(plan, [
        :id,
        :project_id,
        :title,
        :summary,
        :version,
        :archived,
        :created_by_login,
        :created_by_track_id
      ])

  def public_item(item, full \\ true) do
    fields = [:id, :title, :brief, :acceptance, :track_id, :position]
    fields = if full, do: fields ++ [:dependencies], else: fields

    Map.take(item, fields)
    |> Map.put(
      :notes,
      Enum.map(
        item.notes,
        &Map.take(&1, [:id, :body, :created_by_login, :created_by_track_id, :inserted_at])
      )
    )
  end

  defp replace_items(plan, attrs) when is_list(attrs) and length(attrs) <= 100 do
    existing = Store.items(plan.id)
    by_id = Map.new(existing, &{&1.id, &1})

    changesets =
      Enum.with_index(attrs, fn a, position ->
        row = Map.get(by_id, a["id"], %Item{plan_id: plan.id})
        Item.changeset(row, Map.put(a, "position", position))
      end)

    items =
      Enum.map(changesets, fn cs ->
        case Ecto.Changeset.apply_action(cs, :insert) do
          {:ok, item} -> item
          {:error, invalid} -> Store.rollback(invalid)
        end
      end)

    case Graph.validate(items) do
      :ok -> :ok
      {:error, reason} -> Store.rollback(reason)
    end

    protect_assigned(existing, items)
    ids = MapSet.new(items, & &1.id)

    Enum.each(existing, fn row ->
      if not MapSet.member?(ids, row.id), do: save(Store.delete(row))
    end)

    Enum.each(changesets, fn cs ->
      if cs.data.__meta__.state == :loaded,
        do: save(Store.update(cs)),
        else: save(Store.insert(cs))
    end)
  end

  defp replace_items(_, _),
    do: Store.rollback({:unprocessable, "invalid_items", "A plan accepts at most 100 items."})

  defp protect_assigned(existing, items) do
    fields = [:id, :position, :title, :brief, :acceptance, :dependencies]

    Enum.each(existing, fn row ->
      if row.track_id || row.assignment_request do
        replacement = Enum.find(items, &(&1.id == row.id))

        if is_nil(replacement) or Map.take(row, fields) != Map.take(replacement, fields),
          do:
            Store.rollback(
              {:conflict, "item_assigned",
               "Assigned items cannot be edited, reordered or removed."}
            )
      end
    end)
  end

  defp save({:ok, row}), do: row
  defp save({:error, reason}), do: Store.rollback(reason)
end

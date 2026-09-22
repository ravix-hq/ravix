defmodule Ravix.Plans.Assignment do
  @moduledoc "Explicit person-authorized assignment, with committed reservations before provider effects."
  alias Ravix.Accounts.Access
  alias Ravix.{Plans, Tracks}
  alias Ravix.Plans.{Prompt, Store}
  alias Ravix.Tooling.{Authorization, Mutations, Tasks}

  def assign(user, principal, plan_id, assignments, request_id) do
    args = %{"plan_id" => plan_id, "assignments" => assignments, "request_id" => request_id}

    with true <- user.id == principal.user.id,
         :ok <- Authorization.person(principal),
         {:ok, principal} <- Authorization.check(principal, "plans:write"),
         {:ok, principal} <- Authorization.check(principal, "tracks:write"),
         {:ok, plan, _} <- Plans.access(user, plan_id),
         :ok <- valid(assignments, request_id),
         :ok <- targets(user, plan.project_id, assignments) do
      Mutations.run(principal, "assign_items", args, fn ->
        run(principal, plan, assignments, request_id)
      end)
    else
      false -> {:error, :unauthenticated}
      error -> error
    end
  end

  defp run(principal, plan, assignments, request_id) do
    with {:ok, %{items: statuses}} <- Plans.get(principal.user, plan.id),
         :ok <- prompt_size(plan, Store.items(plan.id), assignments),
         {:ok, items} <- reserve(plan, assignments, statuses, request_id) do
      results =
        Enum.map(assignments, fn assignment ->
          item = Enum.find(items, &(&1.id == assignment["item_id"]))
          {item, open(principal, plan, item, assignment)}
        end)

      siblings = Store.items(plan.id)

      receipts =
        Enum.map(results, fn {item, result} ->
          submit(principal, plan, item, siblings, result, request_id)
        end)

      {:ok, %{items: receipts}}
    end
  end

  defp prompt_size(plan, items, assignments) do
    ids = MapSet.new(assignments, & &1["item_id"])
    selected = Enum.filter(items, &MapSet.member?(ids, &1.id))

    if Enum.all?(selected, &(String.length(Prompt.build(plan, &1, items)) <= 95_000)),
      do: :ok,
      else:
        {:error,
         {:unprocessable, "plan_prompt_too_large",
          "Shorten this plan's prompt material before assigning it."}}
  end

  defp reserve(plan, assignments, statuses, request_id) do
    ids = Enum.map(assignments, & &1["item_id"])

    Store.transaction(fn ->
      current = Store.lock(plan.id)

      if current.version != plan.version,
        do:
          Store.rollback(
            {:conflict, "stale_version", "This plan changed. Refresh before assigning."}
          )

      if current.archived,
        do:
          Store.rollback({:conflict, "plan_archived", "Restore this plan before assigning work."})

      items = Store.items(plan.id)
      selected = Enum.filter(items, &(&1.id in ids))
      if length(selected) != length(ids), do: Store.rollback(:not_found)

      Enum.each(selected, &reserve_item(&1, statuses, request_id))

      current |> Ecto.Changeset.change(version: current.version + 1) |> Store.update() |> saved()
      selected
    end)
  end

  defp reserve_item(item, statuses, request_id) do
    status = Enum.find(statuses, &(&1.id == item.id))

    cond do
      item.track_id || item.assignment_request ->
        Store.rollback(
          {:conflict, "item_assigned",
           "This item is already assigned or has an unconfirmed assignment."}
        )

      is_nil(status) or status.status == :blocked ->
        Store.rollback(
          {:conflict, "item_blocked", "Complete dependencies before assigning this item."}
        )

      true ->
        item |> Ecto.Changeset.change(assignment_request: request_id) |> Store.update() |> saved()
    end
  end

  defp open(principal, plan, item, assignment) do
    with {:ok, _} <- Authorization.check(principal, "tracks:write"),
         {:ok, _, _} <- Plans.access(principal.user, plan.id),
         {:ok, track} <- target(principal.user, plan, item, assignment) do
      # Reservation is durable before the provider call; attachment is durable before prompting.
      Store.transaction(fn ->
        Store.lock(plan.id)

        Store.item(item.id)
        |> Ecto.Changeset.change(track_id: track.id)
        |> Store.update()
        |> saved()
      end)

      {:ok, track}
    end
  end

  defp target(user, plan, _item, %{"track_id" => id}) when is_binary(id) do
    with {:ok, %{track: track}} <- Access.track_access(user, id),
         true <- track.project_id == plan.project_id and is_nil(track.closed_at) do
      {:ok, track}
    else
      _ -> {:error, :not_found}
    end
  end

  defp target(user, plan, item, _) do
    Tracks.open(user, plan.project_id, %{
      "title" => item.title,
      "origin" => %{
        "kind" => "plan",
        "plan_id" => plan.id,
        "item_id" => item.id,
        "title" => item.title
      }
    })
  end

  defp submit(principal, plan, item, siblings, {:ok, track}, request_id) do
    case Tasks.send(
           principal,
           track.id,
           Prompt.build(plan, item, siblings),
           "plan:#{request_id}:#{item.id}"
         ) do
      {:ok, task} -> %{item_id: item.id, track_id: track.id, task: Tasks.present(task)}
      {:error, _} -> %{item_id: item.id, track_id: track.id, error: "prompt_unconfirmed"}
    end
  end

  defp submit(_, _, item, _, {:error, _}, _),
    do: %{item_id: item.id, error: "assignment_unconfirmed"}

  defp targets(user, project_id, assignments) do
    if Enum.all?(assignments, &valid_target?(user, project_id, &1)),
      do: :ok,
      else: {:error, :not_found}
  end

  defp valid_target?(user, project_id, %{"track_id" => id}) do
    case Access.track_access(user, id) do
      {:ok, %{track: track}} -> track.project_id == project_id and is_nil(track.closed_at)
      _ -> false
    end
  end

  defp valid_target?(_, _, _), do: true

  defp valid(assignments, request_id)
       when is_list(assignments) and length(assignments) in 1..100 and is_binary(request_id) and
              byte_size(request_id) in 1..100 do
    ids = Enum.map(assignments, fn a -> if is_map(a), do: a["item_id"] end)

    if Enum.all?(ids, &is_binary/1) and length(Enum.uniq(ids)) == length(ids),
      do: :ok,
      else: invalid()
  end

  defp valid(_, _), do: invalid()

  defp invalid,
    do: {:error, {:unprocessable, "invalid_assignment", "Choose unique items and a request ID."}}

  defp saved({:ok, row}), do: row
  defp saved({:error, reason}), do: Store.rollback(reason)
end

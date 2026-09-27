defmodule Ravix.Plans.Status do
  @moduledoc "Derived status, using one bounded batch of the cached GitHub pull requests."
  alias Ravix.Plans.Store

  def items(project, items) do
    tracks = Store.tracks(Enum.flat_map(items, &if(&1.track_id, do: [&1.track_id], else: [])))
    linked = linked_pulls(project, items)
    item_reports = Map.new(items, &{&1.id, item_report(&1, linked)})
    tracks = Map.new(tracks, &{&1.id, &1})

    completed =
      MapSet.new(items |> Enum.filter(&(pull_state(item_reports[&1.id]) == :merged)), & &1.id)

    Enum.map(items, fn item ->
      track = tracks[item.track_id]
      report = item_reports[item.id]

      Ravix.Plans.public_item(item)
      |> Map.merge(%{
        status: derive(item, track, report, completed),
        status_available: report != :unavailable,
        pull: public_pull(report),
        track_url: if(track, do: "/p/#{project.id}/t/#{track.id}"),
        track_title: if(track, do: track.title)
      })
    end)
  end

  defp linked_pulls(_, []), do: {:ok, %{pulls: [], complete: true}}

  defp linked_pulls(%{repo_full_name: repo, installation_id: id}, _)
       when is_binary(repo) and is_integer(id) do
    with {:ok, app} <- Ravix.Providers.github(),
         do: Ravix.GitHub.plan_pulls(app, id, repo)
  end

  defp linked_pulls(_, _), do: {:ok, %{pulls: [], complete: true}}

  defp item_report(item, {:ok, %{pulls: pulls, complete: complete}}) do
    case Enum.filter(pulls, &(item.id in &1.plan_item_ids)) do
      [] ->
        if complete, do: nil, else: :unavailable

      linked ->
        pull = Enum.min_by(linked, &priority/1)
        if complete or pull.state == :merged, do: %{pull: pull}, else: :unavailable
    end
  end

  defp item_report(_, _), do: :unavailable

  defp priority(%{state: :merged, number: number}), do: {0, -number}
  defp priority(%{state: :open, number: number}), do: {1, -number}
  defp priority(%{state: :closed, number: number}), do: {2, -number}

  defp public_pull(%{pull: %{} = pull}), do: Map.take(pull, [:number, :url])
  defp public_pull(_), do: nil

  def derive(item, track, report, completed) do
    case pull_state(report) do
      :merged -> :done
      :closed -> :closed_without_merge
      :open -> :in_review
      _ -> track_status(item, track, completed)
    end
  end

  defp track_status(_item, %{closed_at: at}, _) when not is_nil(at), do: :closed_without_merge
  defp track_status(_item, %{}, _), do: :in_progress

  defp track_status(item, nil, completed) do
    cond do
      Enum.any?(item.dependencies, &(not MapSet.member?(completed, &1))) -> :blocked
      item.dependencies != [] -> :ready
      true -> :unassigned
    end
  end

  defp pull_state(%{pull: %{state: state}}), do: state
  defp pull_state(_), do: nil
end

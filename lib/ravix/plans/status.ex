defmodule Ravix.Plans.Status do
  @moduledoc "Derived status, using one bounded batch of the cached GitHub pull requests."
  alias Ravix.Plans.Store

  def items(project, items) do
    tracks = Store.tracks(Enum.flat_map(items, &if(&1.track_id, do: [&1.track_id], else: [])))
    reports = reports(project, tracks)
    tracks = Map.new(tracks, &{&1.id, &1})

    completed =
      MapSet.new(items |> Enum.filter(&(pull_state(reports[&1.track_id]) == :merged)), & &1.id)

    Enum.map(items, fn item ->
      track = tracks[item.track_id]
      report = reports[item.track_id]

      Ravix.Plans.public_item(item)
      |> Map.merge(%{
        status: derive(item, track, report, completed),
        status_available: report != :unavailable,
        track_url: if(track, do: "/p/#{project.id}/t/#{track.id}"),
        track_title: if(track, do: track.title)
      })
    end)
  end

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

  defp reports(%{repo_full_name: repo, installation_id: installation}, tracks)
       when is_binary(repo) and is_integer(installation) do
    case Ravix.Providers.github() do
      {:ok, app} ->
        Task.Supervisor.async_stream_nolink(
          Ravix.TaskSupervisor,
          tracks,
          Ravix.Trace.link_each(fn track ->
            {track.id,
             Ravix.GitHub.pull_for_track(app, installation, repo, track.branch, %{
               created_at: track.created_at,
               origin_number: if(track.origin_kind == :pr, do: track.origin_number)
             })}
          end),
          max_concurrency: 4,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.zip(tracks)
        |> Map.new(fn
          {{:ok, {id, {:ok, pull}}}, _} -> {id, %{pull: pull}}
          {_, track} -> {track.id, :unavailable}
        end)

      _ ->
        Map.new(tracks, &{&1.id, :unavailable})
    end
  end

  defp reports(_, _), do: %{}
  defp pull_state(%{pull: %{state: state}}), do: state
  defp pull_state(_), do: nil
end

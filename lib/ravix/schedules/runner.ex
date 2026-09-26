defmodule Ravix.Schedules.Runner do
  @moduledoc "Dispatch recurring prompts through the same scoped track and durable prompt queue doors as a person."
  alias Ravix.Accounts.Access
  alias Ravix.Schedules.Store
  alias Ravix.Tracks

  def tick(now \\ DateTime.utc_now()) do
    Enum.each(Store.due(now), &run(&1.id, now))
  end

  def run(id, now) do
    case Store.claim(id, now) do
      {:ok, nil} -> :ok
      {:ok, schedule} -> dispatch(schedule)
      {:error, _} -> :error
    end
  end

  defp track_name(schedule) do
    "#{Ravix.Ids.slugify(schedule.name)}-#{String.slice(schedule.id, 0, 8)}-#{DateTime.to_unix(schedule.last_run_at)}"
  end

  defp dispatch(schedule) do
    user = Store.user(schedule)

    with true <- not is_nil(user),
         {:ok, _} <- Access.project_access(user, schedule.project_id),
         {:ok, track} <-
           Tracks.open(user, schedule.project_id, %{"title" => track_name(schedule)}) do
      case Tracks.prompt(user, track.id, %{
             "prompt" => schedule.prompt,
             "request_id" =>
               "schedule:#{schedule.id}:#{DateTime.to_unix(schedule.last_run_at, :microsecond)}"
           }) do
        {:ok, _} -> Store.finish(schedule, "Prompt queued", track.id)
        {:error, _} -> Store.finish(schedule, "Could not queue prompt", track.id)
      end
    else
      _ ->
        Store.finish(
          schedule,
          "Could not open track; check project access and agent connection",
          nil
        )
    end
  rescue
    _ -> Store.finish(schedule, "Dispatch interrupted; check tracks before trying again", nil)
  end
end

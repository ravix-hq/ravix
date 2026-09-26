defmodule Ravix.Schedules.Store do
  @moduledoc "Scheduler-only persistence. Claims commit before external side effects; never replay a claimed occurrence."
  import Ecto.Query
  alias Ravix.Accounts.Store, as: Accounts
  alias Ravix.Repo
  alias Ravix.Schedules.Schedule

  def due(now) do
    Repo.all(
      from s in Schedule,
        where: s.enabled and s.next_run_at <= ^now,
        order_by: s.next_run_at,
        limit: 50
    )
  end

  def claim(id, now) do
    Repo.transaction(fn ->
      row =
        Repo.one(
          from s in Schedule,
            where: s.id == ^id and s.enabled and s.next_run_at <= ^now,
            lock: "FOR UPDATE SKIP LOCKED"
        )

      if row do
        row
        |> Ecto.Changeset.change(
          next_run_at: Schedule.next_run(row, now),
          last_run_at: now,
          last_status: "Dispatch started; completion not yet confirmed",
          last_track_id: nil
        )
        |> Repo.update!()
      end
    end)
  end

  # ownership: the durable schedule records its creator. The runner rechecks
  # Access.project_access before Tracks.open and Tracks.prompt check it again.
  def user(schedule), do: Accounts.get_user(schedule.user_id)

  def finish(schedule, status, track_id) do
    Repo.update_all(
      from(s in Schedule, where: s.id == ^schedule.id and s.last_run_at == ^schedule.last_run_at),
      set: [last_status: status, last_track_id: track_id, updated_at: DateTime.utc_now()]
    )
  end
end

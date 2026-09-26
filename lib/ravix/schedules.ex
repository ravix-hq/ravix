defmodule Ravix.Schedules do
  @moduledoc "Personal schedules, admitted through current project membership on every operation."
  import Ecto.Query
  alias Ravix.Accounts.{Access, User}
  alias Ravix.Repo
  alias Ravix.Schedules.Schedule

  def list(%User{id: id} = user) do
    Repo.all(from s in Schedule, where: s.user_id == ^id, order_by: [desc: s.inserted_at])
    |> Enum.filter(&match?({:ok, _}, Access.project_access(user, &1.project_id)))
  end

  def create(%User{} = user, project_id, attrs) do
    with {:ok, _} <- Access.project_access(user, project_id) do
      %Schedule{user_id: user.id, project_id: project_id}
      |> Schedule.changeset(attrs)
      |> next_run()
      |> Repo.insert()
    end
  end

  def update(user, id, attrs) do
    with {:ok, schedule} <- get(user, id) do
      schedule |> Schedule.changeset(attrs) |> next_run() |> Repo.update()
    end
  end

  def delete(user, id) do
    with {:ok, schedule} <- get(user, id), do: Repo.delete(schedule)
  end

  def get(%User{id: user_id} = user, id) when is_binary(id) do
    with %Schedule{} = schedule <-
           Repo.one(from s in Schedule, where: s.id == ^id and s.user_id == ^user_id),
         {:ok, _} <- Access.project_access(user, schedule.project_id) do
      {:ok, schedule}
    else
      _ -> {:error, :not_found}
    end
  end

  def get(_user, _id), do: {:error, :not_found}

  defp next_run(%{valid?: true} = changeset) do
    row = Ecto.Changeset.apply_changes(changeset)
    Ecto.Changeset.put_change(changeset, :next_run_at, Schedule.next_run(row, DateTime.utc_now()))
  end

  defp next_run(changeset), do: changeset
end

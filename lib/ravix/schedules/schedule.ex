defmodule Ravix.Schedules.Schedule do
  @moduledoc "A personal recurring prompt, executed in a fresh project track."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}
  schema "schedules" do
    field :user_id, :string
    field :project_id, :string
    field :name, :string
    field :prompt, :string
    field :frequency, Ecto.Enum, values: [:hourly, :daily, :weekly], default: :daily
    field :time, :time, default: ~T[09:00:00]
    field :weekday, :integer, default: 1
    field :enabled, :boolean, default: true
    field :next_run_at, :utc_datetime_usec
    field :last_run_at, :utc_datetime_usec
    field :last_status, :string
    field :last_track_id, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:name, :prompt, :frequency, :time, :weekday, :enabled])
    |> update_change(:name, &trim/1)
    |> update_change(:prompt, &trim/1)
    |> Ravix.Schema.put_new_id()
    |> validate_required([
      :user_id,
      :project_id,
      :name,
      :prompt,
      :frequency,
      :time,
      :weekday,
      :enabled
    ])
    |> validate_length(:name, max: 100)
    |> validate_length(:prompt, max: 100_000)
    |> validate_number(:weekday, greater_than_or_equal_to: 1, less_than_or_equal_to: 7)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  @doc "The first occurrence strictly after now, in UTC. Hourly uses the chosen minute."
  def next_run(schedule, now) do
    today = DateTime.to_date(now)
    time = %{schedule.time | second: 0, microsecond: {0, 0}}

    case schedule.frequency do
      :hourly ->
        candidate = %{now | minute: time.minute, second: 0, microsecond: {0, 0}}
        future(candidate, now, 3600)

      :daily ->
        future(DateTime.new!(today, time), now, 86_400)

      :weekly ->
        days = Integer.mod(schedule.weekday - Date.day_of_week(today), 7)
        future(DateTime.new!(Date.add(today, days), time), now, 7 * 86_400)
    end
  end

  defp future(candidate, now, seconds) do
    candidate = %{candidate | microsecond: {0, 6}}

    if DateTime.compare(candidate, now) == :gt,
      do: candidate,
      else: DateTime.add(candidate, seconds, :second)
  end
end

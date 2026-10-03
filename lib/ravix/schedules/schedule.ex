defmodule Ravix.Schedules.Schedule do
  @moduledoc "A personal recurring prompt, executed in a fresh project track."
  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}
  schema "schedules" do
    field :resource_id, :string
    field :user_id, :string
    field :project_id, :string
    field :name, :string
    field :prompt, :string
    field :frequency, Ecto.Enum, values: [:hourly, :daily, :weekly], default: :daily
    field :time, :time, default: ~T[09:00:00]
    field :weekday, :integer, default: 1
    field :timezone, :string, default: "Etc/UTC"
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
    |> put_timezone(attrs)
    |> Ravix.Schema.put_new_id()
    |> validate_required([
      :user_id,
      :project_id,
      :name,
      :prompt,
      :frequency,
      :time,
      :weekday,
      :timezone,
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

  # Attrs that name no zone keep the stored one; a blank or unknown one is UTC.
  defp put_timezone(changeset, attrs) do
    case Enum.find(attrs, fn {key, _} -> key in ["timezone", :timezone] end) do
      {_, value} -> put_change(changeset, :timezone, timezone(value))
      nil -> changeset
    end
  end

  @utc "Etc/UTC"

  @doc """
  An IANA zone name the time zone database knows, or `"Etc/UTC"` for
  anything else: blank, unknown, overlong or not a string. The lookup matches
  strings and never creates an atom, so browser input is safe to pass here.
  """
  def timezone(value) when is_binary(value) and byte_size(value) <= 64 do
    zone = String.trim(value)

    case DateTime.now(zone) do
      {:ok, _} -> zone
      {:error, _} -> @utc
    end
  end

  def timezone(_value), do: @utc

  @doc """
  The first occurrence strictly after `now`, returned in UTC.

  Daily and weekly times are wall-clock times in the schedule's zone, so 9:00
  stays 9:00 local across daylight saving changes. A time that does not exist
  that day (the spring-forward gap) runs at the first instant after the gap; a
  time that happens twice (the autumn fold) runs once, at its first instance.
  Hourly runs every hour at the chosen local minute.
  """
  def next_run(schedule, now) do
    case DateTime.shift_zone(now, schedule.timezone || @utc) do
      {:ok, local} ->
        next_run(schedule, now, local)

      {:error, reason} ->
        # A zone the database stopped knowing must not raise inside the
        # runner's claim and stall every due row behind it: run on UTC.
        Logger.warning(
          "schedule #{schedule.id} has unusable time zone #{inspect(schedule.timezone)} " <>
            "(#{inspect(reason)}); computing its next run in UTC"
        )

        next_run(%{schedule | timezone: @utc}, now)
    end
  end

  defp next_run(schedule, now, local) do
    zone = local.time_zone
    time = %{schedule.time | second: 0, microsecond: {0, 0}}
    today = DateTime.to_date(local)

    case schedule.frequency do
      :hourly ->
        local
        |> DateTime.to_naive()
        |> Map.merge(%{minute: time.minute, second: 0, microsecond: {0, 0}})
        |> instant(zone)
        |> future_hour(now)

      :daily ->
        future_day(today, time, zone, now, 1)

      :weekly ->
        days = Integer.mod(schedule.weekday - Date.day_of_week(today), 7)
        future_day(Date.add(today, days), time, zone, now, 7)
    end
  end

  defp future_hour(candidate, now) do
    if DateTime.compare(candidate, now) == :gt,
      do: candidate,
      else: future_hour(DateTime.add(candidate, 3600, :second), now)
  end

  defp future_day(date, time, zone, now, step) do
    candidate = instant(NaiveDateTime.new!(date, time), zone)

    if DateTime.compare(candidate, now) == :gt,
      do: candidate,
      else: future_day(Date.add(date, step), time, zone, now, step)
  end

  defp instant(naive, zone) do
    local =
      case DateTime.from_naive(naive, zone) do
        {:ok, local} -> local
        {:ambiguous, first, _second} -> first
        {:gap, _before, just_after} -> just_after
      end

    %{DateTime.shift_zone!(local, @utc) | microsecond: {0, 6}}
  end
end

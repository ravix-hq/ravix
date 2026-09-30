defmodule RavixWeb.LocalTime do
  @moduledoc """
  The server's reading of a timestamp, in the shape the `LocalTime` hook
  (`assets/js/hooks/local_time.js`) writes it: the time alone for today,
  "Sep 28, 4:27 PM" before that, and the year too once it is not this one.

  The zone is the one the browser reported on connect, validated by
  `Ravix.Schedules.timezone/1`, and UTC until it has reported one. This is
  the text a page shows before the hook runs and what a test reads; the
  browser then rewrites it in its own zone and locale. So the server spells
  the zone out only in the `title`, where UTC is "Coordinated Universal
  Time" as the browser names it too, and never writes "16:27 UTC" as text.
  """

  @utc "Etc/UTC"

  @doc "`at` in `zone`, falling back to UTC for a zone the database does not know."
  @spec in_zone(DateTime.t(), String.t() | nil) :: DateTime.t()
  def in_zone(%DateTime{} = at, zone) when is_binary(zone) and zone != @utc do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      {:error, _reason} -> in_zone(at, @utc)
    end
  end

  def in_zone(%DateTime{} = at, _zone), do: DateTime.shift_zone!(at, @utc)

  @doc "The short form, relative to `now` for what counts as today."
  @spec short(DateTime.t(), String.t() | nil, DateTime.t()) :: String.t()
  def short(%DateTime{} = at, zone, %DateTime{} = now \\ DateTime.utc_now()) do
    local = in_zone(at, zone)
    today = in_zone(now, zone)
    time = Calendar.strftime(local, "%-I:%M %p")

    cond do
      DateTime.to_date(local) == DateTime.to_date(today) -> time
      local.year == today.year -> Calendar.strftime(local, "%b %-d, ") <> time
      true -> Calendar.strftime(local, "%b %-d, %Y, ") <> time
    end
  end

  @doc "The full form for a `title`: weekday, date, time and the zone's name."
  @spec full(DateTime.t(), String.t() | nil) :: String.t()
  def full(%DateTime{} = at, zone) do
    local = in_zone(at, zone)
    Calendar.strftime(local, "%a, %b %-d, %Y, %-I:%M %p ") <> zone_name(local)
  end

  defp zone_name(%DateTime{time_zone: @utc}), do: "Coordinated Universal Time"
  defp zone_name(%DateTime{zone_abbr: abbr}), do: abbr
end

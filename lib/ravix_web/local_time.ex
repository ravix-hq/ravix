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

  @ages [
    {365 * 86_400, "y", "year"},
    {30 * 86_400, "mo", "month"},
    {86_400, "d", "day"},
    {3_600, "h", "hour"},
    {60, "m", "minute"}
  ]

  @doc """
  How long ago, as `{short, words}` ("2h", "2 hours ago"), the way
  `assets/js/hooks/relative_time.js`'s `age` answers it: the server's text
  before the `RelativeTime` hook keeps it current.
  """
  @spec ago(DateTime.t(), DateTime.t()) :: {String.t(), String.t()}
  def ago(%DateTime{} = at, %DateTime{} = now \\ DateTime.utc_now()) do
    seconds = max(DateTime.diff(now, at), 0)

    case Enum.find(@ages, fn {size, _, _} -> seconds >= size end) do
      nil ->
        {"now", "just now"}

      {size, short, word} ->
        n = div(seconds, size)
        {"#{n}#{short}", "#{n} #{word}#{if n == 1, do: "", else: "s"} ago"}
    end
  end

  @doc ~S'The `data-style="ago"` text: "2h ago", or "just now".'
  @spec ago_words(DateTime.t(), DateTime.t()) :: String.t()
  def ago_words(%DateTime{} = at, %DateTime{} = now \\ DateTime.utc_now()) do
    case ago(at, now) do
      {"now", _words} -> "just now"
      {short, _words} -> short <> " ago"
    end
  end

  defp zone_name(%DateTime{time_zone: @utc}), do: "Coordinated Universal Time"
  defp zone_name(%DateTime{zone_abbr: abbr}), do: abbr
end

defmodule RavixWeb.LocalTimeTest do
  use ExUnit.Case, async: true
  @moduletag :deprecated_literal_ui

  alias RavixWeb.LocalTime

  # Wednesday 30 September 2026, 08:00 in New York.
  @now ~U[2026-09-30 12:00:00Z]
  @zone "America/New_York"

  test "the short form is the time today, else the date and time" do
    assert LocalTime.short(~U[2026-09-30 13:05:00Z], @zone, @now) == "9:05 AM"
    assert LocalTime.short(~U[2026-09-27 01:49:00Z], @zone, @now) == "Sep 26, 9:49 PM"
    assert LocalTime.short(~U[2025-12-31 20:00:00Z], @zone, @now) == "Dec 31, 2025, 3:00 PM"
  end

  # RAV-93: a turn's footer names the six days before today by weekday.
  test "with weekday, the six days before today are named by weekday" do
    short = &LocalTime.short(&1, @zone, @now, weekday: true)

    assert short.(~U[2026-09-30 13:05:00Z]) == "9:05 AM"
    assert short.(~U[2026-09-27 01:49:00Z]) == "Sat 9:49 PM"
    assert short.(~U[2026-09-29 20:00:00Z]) == "Tue 4:00 PM"
    assert short.(~U[2026-09-24 16:00:00Z]) == "Thu 12:00 PM"
    # Seven days back is a date again, so "Wed" never means two days.
    assert short.(~U[2026-09-23 16:00:00Z]) == "Sep 23, 12:00 PM"
  end
end

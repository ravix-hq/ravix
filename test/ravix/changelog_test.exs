defmodule Ravix.ChangelogTest do
  use ExUnit.Case, async: true

  test "the checked-in changelog is valid and ordered newest first" do
    assert :ok = Ravix.Changelog.validate()
    dates = Enum.map(Ravix.Changelog.all(), & &1.date)
    assert dates == Enum.sort(dates, {:desc, Date})
  end

  test "since returns only entries newer than the marker" do
    assert Enum.map(Ravix.Changelog.since(~U[2026-09-25 00:00:00Z]), & &1.id) ==
             [
               "2026-10-01-connect-step",
               "2026-09-30-effort-and-fast",
               "2026-09-30-terminals",
               "2026-09-28-thread-default",
               "2026-09-26-threads"
             ]

    assert Ravix.Changelog.since(~U[2027-01-01 00:00:00Z]) == []
  end

  test "newest picks by the calendar, so the 1st of a month beats the 30th before it" do
    first = %{id: "first", date: ~D[2026-10-01]}
    thirtieth = %{id: "thirtieth", date: ~D[2026-09-30]}

    assert Ravix.Changelog.newest([thirtieth, first]) == first
    assert Ravix.Changelog.newest([first, thirtieth]) == first
    assert Ravix.Changelog.newest(Ravix.Changelog.all()) == hd(Ravix.Changelog.all())
    assert Ravix.Changelog.newest([]) == nil
  end

  test "acknowledging the newest entry leaves nothing unseen" do
    marker = Ravix.Changelog.at(Ravix.Changelog.newest(Ravix.Changelog.all()))
    assert Ravix.Changelog.since(marker) == []
  end
end

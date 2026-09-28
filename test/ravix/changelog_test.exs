defmodule Ravix.ChangelogTest do
  use ExUnit.Case, async: true

  test "the checked-in changelog is valid and ordered newest first" do
    assert :ok = Ravix.Changelog.validate()
    dates = Enum.map(Ravix.Changelog.all(), & &1.date)
    assert dates == Enum.sort(dates, {:desc, Date})
  end

  test "since returns only entries newer than the marker" do
    assert Enum.map(Ravix.Changelog.since(~U[2026-09-25 00:00:00Z]), & &1.id) ==
             ["2026-09-28-thread-default", "2026-09-26-threads"]

    assert Ravix.Changelog.since(~U[2027-01-01 00:00:00Z]) == []
  end
end

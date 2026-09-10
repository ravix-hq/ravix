defmodule Ravix.Tracks.NamesTest do
  use ExUnit.Case, async: true

  alias Ravix.Tracks.Names

  test "the walk starts where the random says and skips names already spent, closed ones included" do
    [first, second | _] = Names.yards()
    assert Names.name_track([], fn -> 0.0 end) == first
    # A closed track's slug is free in the database, but its branch is not.
    assert Names.name_track([String.downcase(first)], fn -> 0.0 end) == second
  end

  test "a project that has used every yard gets a numbered one rather than a refusal" do
    assert Names.name_track(Names.yards(), fn -> 0.0 end) == "#{hd(Names.yards())} 2"

    assert Names.name_track(Names.yards() ++ ["#{hd(Names.yards())} 2"], fn -> 0.0 end) ==
             "#{hd(Names.yards())} 3"
  end

  test "every yard slugifies to something distinct and fit for a directory" do
    slugs = Enum.map(Names.yards(), &Ravix.Ids.slugify/1)
    assert length(Enum.uniq(slugs)) == length(slugs)
    assert Enum.all?(slugs, &(&1 =~ ~r/^[a-z0-9-]+$/))
  end
end

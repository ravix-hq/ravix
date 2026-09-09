defmodule Ravix.CoverageTest do
  use ExUnit.Case, async: true

  test "clause entries collapse by line, any hit covers the line, and line zero is ignored" do
    assert Ravix.Coverage.line_counts([
             {{Example, 0}, {0, 1}},
             {{Example, 1}, {0, 1}},
             {{Example, 1}, {1, 0}},
             {{Example, 2}, {1, 0}},
             {{Example, 2}, {0, 1}},
             {{Example, 3}, {0, 1}}
           ]) == {2, 3}

    assert Ravix.Coverage.line_counts([]) == {0, 0}
  end
end

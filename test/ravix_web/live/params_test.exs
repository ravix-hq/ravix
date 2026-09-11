defmodule RavixWeb.Live.ParamsTest do
  @moduledoc """
  The three readings of a checkbox that had grown up inline across two
  LiveViews, now one function with the default as an argument.
  """
  use ExUnit.Case, async: true

  alias RavixWeb.Live.Params

  describe "flag/3" do
    test "reads the two words a form actually sends" do
      assert Params.flag(%{"draft" => "true"}, "draft", false)
      refute Params.flag(%{"draft" => "false"}, "draft", true)
    end

    test "takes the default when the form sent nothing" do
      # An unchecked checkbox is absent, not `"false"`, which is why the
      # default has to be said out loud. `draft` defaults true (a pull
      # request opens as a draft unless you say otherwise) and `force`
      # defaults false (closing a track with unpushed work needs asking for).
      assert Params.flag(%{}, "draft", true)
      refute Params.flag(%{}, "force", false)
      refute Params.flag(%{"other" => "true"}, "force", false)
    end

    test "is not fooled by a value that is not a checkbox" do
      # `"0"`, `"on"` and `nil` are all "the form did not send a checkbox",
      # and guessing at them is how `"0"` reads as true.
      for value <- ["0", "1", "on", "", nil, 1] do
        refute Params.flag(%{"x" => value}, "x", false)
        assert Params.flag(%{"x" => value}, "x", true)
      end
    end

    test "defaults to false when no default is given" do
      refute Params.flag(%{}, "x")
    end
  end
end

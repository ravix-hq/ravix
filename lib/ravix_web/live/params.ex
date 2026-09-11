defmodule RavixWeb.Live.Params do
  @moduledoc """
  What a form actually sends, read once and named.

  A checkbox arrives as `"true"`, `"false"`, or not at all, and three
  different readings of that had grown up in two LiveViews:

      params["clear"] == "true"     # absent means false
      params["force"] == "true"     # absent means false
      params["draft"] != "false"    # absent means *true*

  All three are correct and the third is deliberate, but written inline the
  default is something a reader has to work out from which comparison was
  used. `flag/3` takes it as an argument instead, so the two cases read the
  same and differ where they actually differ.
  """

  @doc """
  The boolean under `key`, or `default` when the form did not send one.

  Only the two words a form sends decide; anything else is the default,
  because a value that is neither is not a checkbox and guessing at it is
  how `"0"` became true.
  """
  @spec flag(map(), String.t(), boolean()) :: boolean()
  def flag(params, key, default \\ false) when is_map(params) and is_boolean(default) do
    case Map.get(params, key) do
      "true" -> true
      "false" -> false
      _absent_or_other -> default
    end
  end
end

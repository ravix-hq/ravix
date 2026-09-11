defmodule Ravix.Spec.Starter do
  @moduledoc """
  One of the chips offered on an empty track: what the button says, and what
  it puts in the composer.

  The prompt is inserted into the box rather than sent, because a starter is
  a draft somebody edits before they mean it --- which is why
  `Ravix.Spec.starters/1` writes them long enough to be worth editing.
  """

  @enforce_keys [:label, :prompt]
  defstruct @enforce_keys

  @type t :: %__MODULE__{label: String.t(), prompt: String.t()}
end

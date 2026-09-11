defmodule Ravix.Projects.Machine.Harness do
  @moduledoc """
  Which agent runs, and which model it runs: the two columns Fountain builds
  an agent from.

  `Ravix.Projects.Machine.pick_runtime/1`'s answer. Both are provider-prefixed
  strings in Fountain's own vocabulary, which is why they are not atoms --- the
  catalog decides what exists and Ravix only compares against one default.

  A struct rather than the `%{runtime: String.t(), model: String.t()}` it was,
  for the reason `Ravix.Projects.MachineState` gives: two fields spelled by
  hand at the three places that build or read a harness is two fields that can
  disagree, and `Ravix.Projects.Settings` already calls the pair by this name
  (`harness/3`, `validate_harness/3`).
  """

  @enforce_keys [:runtime, :model]
  defstruct @enforce_keys

  @type t :: %__MODULE__{runtime: String.t(), model: String.t()}
end

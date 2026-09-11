defmodule Ravix.MachineCache.Machine do
  @moduledoc """
  Which machine a project is on: one field, and the one that identifies it.

  `Ravix.MachineCache.machine_of/3` derives this from the project's
  conversations rather than reading it from a column --- see that module for
  why --- and every caller that needs to reach the box goes through it: the
  file, diff and listing routes, the terminal, the vitals probe, the preview
  reconciler and the agent helper.

  One field is the point, not an accident. `GET /api/conversations` serves
  `"sandbox": null`, so the list carries a sandbox id and nothing else about
  the sandbox; `sprite_name` costs a second Fountain call and is asked for
  separately by `Ravix.MachineCache.sprite_for/3`. A struct with exactly the
  one field it can honestly answer is the shape that says so.
  `Ravix.Projects.MachineState` is the other, wider one --- what the
  settings dialog shows, filled in by a caller that did pay for the rest.

  It was `%{sandbox_id: String.t()} | nil`, declared here and again in
  `Ravix.Projects.View`, which is the failure mode of a structural type
  written twice: the two spellings happened to agree, and nothing was
  checking that they did.

  `nil`, not an empty struct, is still the answer for a project whose
  conversations name no machine. Every caller branches on that and there is
  nothing to read in the case.
  """

  @enforce_keys [:sandbox_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{sandbox_id: String.t()}
end

defmodule Ravix.Projects.MachineState do
  @moduledoc """
  Whether a project has a machine, and what it is doing.

  `sprite_name` is deliberately never filled in here: the conversation list
  serves `"sandbox": null`, so the only honest answer at this distance is
  "not read", and the terminal asks `Ravix.Tracks.sprite_for/1` when it
  actually needs one. The field stays because the shape is what the pages
  read, and a field that is always nil and says why is better than a field
  that is sometimes absent and does not.

  A struct rather than the bare map it was: `@enforce_keys` means
  `Machine.state/1` and `Machine.none/0` cannot answer with three fields on
  one path and two on another.
  """

  @enforce_keys [:sandbox_id, :status, :sprite_name]
  defstruct @enforce_keys

  @typedoc "What Fountain says the machine is doing, narrowed to what Ravix acts on."
  @type status :: :none | :pending | :starting | :ready | :suspended | :terminated | :failed

  @type t :: %__MODULE__{
          sandbox_id: String.t() | nil,
          status: status(),
          sprite_name: String.t() | nil
        }
end

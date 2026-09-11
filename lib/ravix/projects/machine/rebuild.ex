defmodule Ravix.Projects.Machine.Rebuild do
  @moduledoc """
  What a rebuild removed, and what would not go.

  `Ravix.Projects.Machine.rebuild/2`'s answer, and it crosses the context
  boundary: `Ravix.Projects.rebuild/2` returns it to the settings dialog.

  Retiring the agent is the one removal that has to work, so it is the one
  that refuses the whole operation; terminating the live conversations first
  is best-effort, and a conversation that would not terminate belongs in
  `failed` rather than stopping the rebuild. `removed` names what went, in
  the order it went.

  A struct, and `Failure` is a struct too, because a map inside a map is
  where a field name stops being checked at all: `failed` was
  `[%{what: String.t(), why: String.t()}]`, a shape declared once in a type
  nothing enforced and built once in a `reduce`, 180 lines apart.
  """

  defmodule Failure do
    @moduledoc "One thing a rebuild could not remove, and the reason Fountain gave."

    @enforce_keys [:what, :why]
    defstruct @enforce_keys

    @type t :: %__MODULE__{what: String.t(), why: String.t()}
  end

  @enforce_keys [:removed, :failed]
  defstruct @enforce_keys

  @type t :: %__MODULE__{removed: [String.t()], failed: [Failure.t()]}
end

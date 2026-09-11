defmodule Ravix.Tracks.Transcript.Edit do
  @moduledoc """
  One file an edit tool changed, as near a real diff as the adapter allows.

  See `Ravix.Tracks.Transcript.edit/3` for how the lines are framed: ACP's
  `diff` content is two whole strings, so the shared runs at each end are
  found by walking in from both, which is exact about what changed and only
  imprecise about how tightly it is framed.

  `added` and `removed` are counts of the lines this edit is *about*, not of
  the `lines` list, which also carries a line of context either side.
  """

  defmodule Line do
    @moduledoc """
    One line of a rendered edit. `:ctx` is unchanged context, kept so a
    one-line change can be placed; `:del` and `:add` are the change itself.
    """

    @enforce_keys [:kind, :text]
    defstruct [:kind, :text]

    @type t :: %__MODULE__{kind: :add | :del | :ctx, text: String.t()}
  end

  @enforce_keys [:path, :lines, :added, :removed]
  defstruct [:path, :lines, :added, :removed]

  @type t :: %__MODULE__{
          path: String.t(),
          lines: [Line.t()],
          added: non_neg_integer(),
          removed: non_neg_integer()
        }
end

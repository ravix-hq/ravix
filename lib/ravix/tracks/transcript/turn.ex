defmodule Ravix.Tracks.Transcript.Turn do
  @moduledoc """
  One turn as the page carries it: what Fountain recorded, plus the events
  that answered it and the blocks they fold into.

  Distinct from `Ravix.Fountain.Shapes.Turn`, which is only the part that
  comes off the wire. This is that record in the container the transcript
  grows: `events` and `blocks` accumulate as output arrives, and `settled?`
  and `visible?` are read off them.

  ## Why only `id` is enforced

  The wire fields are genuinely absent on a turn the event log named before
  Fountain finished recording it -- `place/3` builds one from a `turn_id`
  alone so the first frames of a new turn are not dropped -- so enforcing
  `prompt` would make a real case unrepresentable. The derived fields are
  never passed in: `Ravix.Tracks.Transcript.finish/2` computes all four on
  every rebuild, so a default here is the value before the first fold rather
  than a field somebody may forget.

  `fold` is that reduction carried between events, and is the reason a
  streaming turn does not re-parse its whole history per frame. It used to be
  an `:acc` key put on the map by `finish/2` and named in no type at all,
  which is the shape of bug this conversion exists to prevent: the `@type`
  said nine fields and the value had ten.
  """

  alias Ravix.Tracks.Transcript.{Block, Event}

  @typedoc """
  The blocks so far, newest first, and where each tool call sits in that list
  so its result can be paired onto it. Internal to the fold; read it through
  `blocks` instead.
  """
  @type fold :: {[Block.t()], %{optional(String.t()) => non_neg_integer()}}

  @enforce_keys [:id]
  defstruct [
    :id,
    :prompt,
    :origin,
    :status,
    :inserted_at,
    events: [],
    blocks: [],
    settled?: false,
    visible?: false,
    fold: {[], %{}}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          prompt: String.t() | nil,
          origin: String.t() | nil,
          status: String.t() | nil,
          inserted_at: String.t() | nil,
          events: [Event.t()],
          blocks: [Block.t()],
          settled?: boolean(),
          visible?: boolean(),
          fold: fold()
        }

  @doc "An empty fold, for a turn whose events have not been read yet."
  @spec empty_fold() :: fold()
  def empty_fold, do: {[], %{}}
end

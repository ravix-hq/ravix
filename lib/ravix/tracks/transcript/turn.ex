defmodule Ravix.Tracks.Transcript.Turn do
  @moduledoc """
  One turn as the page carries it: the prompt that opened it, the events
  that answered it, and the blocks they fold into.

  Built from the event log and retained image counts (see `Ravix.Tracks.Transcript`), so it is
  not `Ravix.Fountain.Shapes.Turn`, the `/turns` record: `prompt` comes off
  the turn's `started` event, `events` and `blocks` accumulate as output
  arrives, and `settled?` and `visible?` are read off them.

  ## Both accumulators are newest first

  `events` is kept in the order `fold` is, which is the reverse of the order
  the events happened in. A live turn takes one event at a time and does so
  thousands of times, so putting each one on the end meant copying the whole
  list per frame, and the head is also where the two questions actually asked
  of the list live: whether this event is newer than everything already here,
  and what the last one was. `Ravix.Tracks.Transcript` reverses once when it
  has to rebuild the fold from scratch, which happens when events arrive out
  of order and not otherwise.

  ## Why only `id` is enforced

  `prompt` is genuinely absent on a turn nobody typed (Fountain's autonomous
  ones), and on the events grouped under `Event.pending/0` before Fountain
  finished recording a turn -- `place/3` builds a turn from a `turn_id` alone
  so those first frames are not dropped -- so enforcing it would make a real
  case unrepresentable. The derived fields are
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
  The blocks so far, newest first. Internal to the fold; read it through
  `blocks` instead.

  It used to carry a second map from tool id to the position of that call in
  this list, so a `tool_result` could be paired onto its `tool_use` by
  arithmetic. `Ravix.Tracks.Transcript` now finds the call by matching the
  `%Block.Tool{}` that holds the id, which is what the struct is for, so
  there is nothing to carry beside the blocks.
  """
  @type fold :: [Block.t()]

  @enforce_keys [:id]
  defstruct [
    :id,
    :prompt,
    image_count: 0,
    events: [],
    blocks: [],
    settled?: false,
    visible?: false,
    fold: []
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          prompt: String.t() | nil,
          image_count: non_neg_integer(),
          events: [Event.t()],
          blocks: [Block.t()],
          settled?: boolean(),
          visible?: boolean(),
          fold: fold()
        }

  @doc "An empty fold, for a turn whose events have not been read yet."
  @spec empty_fold() :: fold()
  def empty_fold, do: []
end

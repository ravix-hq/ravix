defmodule Ravix.Tracks.Transcript.Page do
  @moduledoc """
  The transcript so far: turns in the order they were asked, and the newest
  event id the page has seen.

  `last_event_id` is what `Ravix.Tracks.Follower.subscribe/2` resumes from,
  so a page is also the cursor for its own live stream; `nil` means nothing
  has arrived yet and is not the same as `0`.

  `oldest_conversation_id` and `oldest_event_id` identify the history edge;
  `history` holds unread chunks and archived conversations, never a live cursor.

  `runtime` decides how output is parsed -- an ACP runtime's stdout is
  dropped because the same content arrives structured -- and is carried on
  the page rather than passed alongside it, because every function that folds
  an event needs it and threading it separately is how the two got out of
  step.
  """

  alias Ravix.Tracks.Transcript.Turn

  @enforce_keys [:turns, :last_event_id, :runtime]
  defstruct turns: [],
            last_event_id: nil,
            runtime: "",
            conversation_id: nil,
            oldest_event_id: nil,
            oldest_conversation_id: nil,
            history: nil

  @type t :: %__MODULE__{
          turns: [Turn.t()],
          last_event_id: integer() | nil,
          conversation_id: String.t() | nil,
          runtime: String.t(),
          oldest_event_id: integer() | nil,
          oldest_conversation_id: String.t() | nil,
          history: Ravix.Tracks.Transcript.History.t() | nil
        }
end

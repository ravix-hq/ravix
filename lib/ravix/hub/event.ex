defmodule Ravix.Hub.Event do
  @moduledoc """
  One thing that happened on a project, in a shape a reader can route on.

  The TypeScript hub was a server-sent stream and each event carried the
  fields the browser needed to decide what to re-fetch: a turn's status, a
  settings revision, the id of the track that changed. When the browser
  became a LiveView the fields came across unchanged and the deciding did
  not: both pages handled every event with a catch-all that re-read
  everything. So the payloads were carried and never read, and `turn` was
  published with `status: "running"` from one caller and `status: :ready`
  from another for a year without anything noticing, because nothing looked.

  This is the set of fields that are actually read, as a struct, so that a
  reader pattern-matches and a typo is a compile error rather than a clause
  that silently never matches:

    * `name` -- which of the six things happened. An atom, and a bounded
      one: these are written here, never received from outside.
    * `project_id` -- the topic it went out on, so a reader holding several
      does not have to infer it.
    * `track_id` -- **the routing field.** The track this concerns, or `nil`
      when it concerns the project as a whole (somebody added to every
      track, the settings moved, the machine rebuilt). A page showing one
      track ignores an event naming a different one; `nil` it must not
      ignore.
    * `present` -- who is looking, for `:here` and nothing else.

  What is deliberately *not* here is `turn`'s status and `settings`'s
  revision. No reader ever took them, and a reader that wanted either would
  be wrong to trust a broadcast for it: the status of a turn is Fountain's
  to answer and `Ravix.Tracks.get/2` asks it live, precisely so a page does
  not show a machine that died while an old message was in flight.

  ## The names

    * `:people` -- who can reach a track (`track_id`) or the project (`nil`)
    * `:tracks` -- a track opened, closed, was renamed or was read
      (`track_id`), or every track on the project changed at once (`nil`,
      from a rebuild or a delete)
    * `:turn` -- a track's machine started or failed to start a turn
    * `:queue` -- a track's queued prompts changed
    * `:settings` -- the project's settings moved, so every track's `stale`
      may have changed
    * `:here` -- who is looking at a track right now, with `present`
  """

  @names [:people, :tracks, :turn, :queue, :settings, :here]

  @typedoc "Which of the six things happened."
  @type name :: :people | :tracks | :turn | :queue | :settings | :here

  @type t :: %__MODULE__{
          name: name(),
          project_id: String.t(),
          track_id: String.t() | nil,
          present: [map()]
        }

  @enforce_keys [:name, :project_id]
  defstruct [:name, :project_id, :track_id, present: []]

  @doc "Every event name, for a reader that wants to be exhaustive."
  @spec names() :: [name()]
  def names, do: @names

  @doc """
  An event on `project_id`.

  Options are the struct's own optional fields: `:track_id` and, for
  `:here`, `:present`. Leaving `:track_id` out says the event is the whole
  project's, which is a wider claim than naming a track and never the
  lazier one to make: a reader takes it as "this may concern you whatever
  you are showing".
  """
  @spec new(name(), String.t(), keyword()) :: t()
  def new(name, project_id, opts \\ []) when name in @names and is_binary(project_id) do
    %__MODULE__{
      name: name,
      project_id: project_id,
      track_id: Keyword.get(opts, :track_id),
      present: Keyword.get(opts, :present, [])
    }
  end

  @doc """
  Whether a page showing `track_id` has to do anything about this event.

  True when the event names that track, and true when it names no track at
  all, because that is the project-wide case and the page is on the
  project. False only when the event is demonstrably somebody else's: a
  sibling track's queue, a sibling track's turn, an invitation to a branch
  this page is not showing.

  This is the whole of the saving. A project with ten tracks being worked
  on used to cost every open page a full re-read -- the track, its queue and
  its transcript -- for every event on any of them.
  """
  @spec concerns?(t(), String.t()) :: boolean()
  def concerns?(%__MODULE__{track_id: nil}, _track_id), do: true
  def concerns?(%__MODULE__{track_id: id}, track_id), do: id == track_id
end

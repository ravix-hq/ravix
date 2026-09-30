defmodule Ravix.Accounts.TrackAccess do
  @moduledoc """
  What `Ravix.Accounts.Access.track_access/2` answers: the track, the project
  it belongs to, and the capacity the caller reaches it in.

  The project comes back alongside the track because almost every caller
  needs both and re-reading it would be a second query against a row the door
  has already had to load to decide the answer.

  Private tracks first require creator or track membership; project ownership
  alone never admits their owner.

  `role` is `:owner` only for the owner of the *project*. Somebody named on
  the track and somebody named on the whole project both arrive as `:member`:
  the difference between them is how they got here, not what they may do once
  they are. See `Ravix.Accounts.ProjectAccess` for why this is a struct.

  `level` is what they may do (ADR 0010): `:read`, `:write` or `:admin`, from
  the nearest grant that reaches this track -- owner, then this track's own,
  then the project's, then the workspace's (RAV-75). The owner is always
  `:admin`, except on somebody else's private track.
  """

  alias Ravix.Accounts.Access
  alias Ravix.Projects.Project
  alias Ravix.Tracks.Track

  @enforce_keys [:track, :project, :role, :level]
  defstruct [:track, :project, :role, :level]

  @type t :: %__MODULE__{
          track: Track.t(),
          project: Project.t(),
          role: Access.role(),
          level: Access.level()
        }
end

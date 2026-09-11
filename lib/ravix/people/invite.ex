defmodule Ravix.People.Invite do
  @moduledoc """
  An invitation waiting on a track or a project: the GitHub account it names,
  and nothing about access, because there is none yet.

  `Ravix.People.Store` reads it off `TrackInvite` and `ProjectInvite`, which
  are two tables with these three columns in common, and turns each into a
  `Ravix.People.Person` marked `:pending`.

  It was declared a map, with a moduledoc arguing that a projection with one
  reader has no boundary for a struct to guard. Two things were wrong with
  that. The reader is not one: `invites_of/1` and `project_invites_of/1` are
  public and the people tests read `login` and `github_id` off them. And the
  projection is not one either --- `invites_on/3` builds it in a `select:`,
  and `invites_by_track/1`, three hundred lines away, builds the same three
  keys again in its own. Two `select:` expressions agreeing about a shape by
  hand is the thing a struct is for; `select: %Invite{}` makes them one
  shape that Ecto fills.

  `github_id` is the identity that survives a rename, which is why it is
  kept even though only `login` and `avatar_url` are rendered.
  """

  @enforce_keys [:github_id, :login, :avatar_url]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          github_id: String.t(),
          login: String.t(),
          avatar_url: String.t() | nil
        }
end

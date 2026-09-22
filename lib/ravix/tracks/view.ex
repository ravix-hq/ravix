defmodule Ravix.Tracks.View do
  @moduledoc """
  A track as a page shows it: the row, plus what had to be asked elsewhere.

  `owner_login` identifies the project owner, independently of who created
  the track. It is taken from the already-scoped people list.

  Deliberately not the `Ravix.Tracks.Track` schema with extra fields on it.
  That schema argues against exactly that in its own documentation -- status,
  turn count and whether the machine is up are read live because "caching
  them here is how a UI ends up confidently showing a machine that died an
  hour ago" -- and a virtual field is still a field on the row, reading as
  nil on every track that came back from `Repo.get/2` without being
  presented. So the two shapes stay two shapes.

  What it *is* rather than the bare map it used to be is a struct, and
  `@enforce_keys` covers every field. `present/2` assembles a track from a
  row, a live conversation, a project and a read mark, and forgetting one of
  those on a new field is the mistake this makes loud: a missing key raises
  where it is built, and a misspelt one no longer compiles.
  """

  alias Ravix.People.Person
  alias Ravix.Tracks.Origin

  @typedoc """
  `:opening` until the machine answers, then whatever the conversation says.
  `:closed` outranks all of them: a closed track has no live half left.
  """
  @type status :: :opening | :ready | :running | :failed | :closed

  @enforce_keys [
    :id,
    :project_id,
    :owner_login,
    :conversation_id,
    :slug,
    :title,
    :branch,
    :workdir,
    :origin,
    :status,
    :stale,
    :opened_at,
    :last_active_at,
    :turn_count,
    :created_at,
    :created_by_login,
    :people,
    :role,
    :unread
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          project_id: String.t(),
          owner_login: String.t(),
          conversation_id: String.t() | nil,
          slug: String.t(),
          title: String.t(),
          branch: String.t(),
          workdir: String.t(),
          origin: Origin.t(),
          status: status(),
          stale: boolean(),
          opened_at: DateTime.t() | nil,
          last_active_at: DateTime.t() | nil,
          turn_count: non_neg_integer(),
          created_at: DateTime.t(),
          created_by_login: String.t(),
          people: [Person.t()],
          role: :owner | :member,
          unread: boolean()
        }
end

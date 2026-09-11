defmodule Ravix.Presence.Watcher do
  @moduledoc """
  Somebody with a track open right now, and whether they are typing.

  One entry per person, not per tab: two windows on the same track are one
  watcher, typing if either of them is. That collapsing is why this is a
  shape of its own rather than the presence meta the tracker holds ---
  `Ravix.Presence.present/2` reads several metas and answers one of these.

  It was the `Presence` of `shared/api.ts`, translated as a bare map. A
  struct because it is rendered directly (`@present` in the track page's
  composer) and because `typing` is a boolean whose absence and whose
  `false` mean different things to that template; `@enforce_keys` makes a
  watcher assembled without it a build error rather than a name that never
  shows as typing.
  """

  @enforce_keys [:login, :name, :avatar_url, :typing]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          login: String.t(),
          name: String.t() | nil,
          avatar_url: String.t() | nil,
          typing: boolean()
        }
end

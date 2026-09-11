defmodule Ravix.People.Person do
  @moduledoc """
  Somebody in a people list, and how they come to be in it.

  `via` is the whole reason a list is worth reading twice. `:owner` holds
  the project and cannot be removed from anything. `:project` was let into
  the machine and reaches every track on it, so a *track's* dialog cannot
  take them off --- that is the project's people to change. `:track` was
  named on this one branch. `:pending` is an invitation nobody has taken up
  yet: they can read nothing until they sign in, and withdrawing it is not
  a removal.

  Every entry carries one of the four, so a page never has to infer which
  by the absence of a key. `@enforce_keys` covers `via` as well, which is
  what makes that a property rather than a convention: the list used to be
  assembled by `Map.put(profile, :via, :project)`, and a fourth way of
  getting into a list that forgot the `Map.put` would have produced a
  person the dialog renders with no badge and a remove button that
  `Ravix.People.remove/3` then refuses.
  """

  alias Ravix.Accounts.User
  alias Ravix.People.Profile

  @typedoc "How this person comes to be in the list."
  @type via :: :owner | :project | :track | :pending

  @enforce_keys [:login, :name, :avatar_url, :via]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          login: String.t(),
          name: String.t() | nil,
          avatar_url: String.t() | nil,
          via: via()
        }

  @doc "A profile, or the user row behind one, placed in a list by `via`."
  @spec new(Profile.t() | User.t(), via()) :: t()
  def new(%User{} = user, via), do: user |> Profile.from_user() |> new(via)

  def new(%Profile{} = profile, via) when via in [:owner, :project, :track, :pending],
    do: %__MODULE__{
      login: profile.login,
      name: profile.name,
      avatar_url: profile.avatar_url,
      via: via
    }

  @doc """
  Somebody invited who has not signed in.

  There is no user row yet, so there is no display name to show; the login
  and avatar are what the invitation was addressed to.
  """
  @spec pending(String.t(), String.t() | nil) :: t()
  def pending(login, avatar_url),
    do: %__MODULE__{login: login, name: nil, avatar_url: avatar_url, via: :pending}
end

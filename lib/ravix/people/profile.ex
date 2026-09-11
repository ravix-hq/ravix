defmodule Ravix.People.Profile do
  @moduledoc """
  What GitHub already publishes about somebody, with no claim about access.

  The invite box's autocomplete answers in these: a name it suggests is a
  GitHub account, not somebody who is in anything yet. It is deliberately
  three fields and no more --- never an email, and never anything about
  what they have here --- because `Ravix.People.search/2` needs a session
  but not an invitation, so this is the one shape a signed-in stranger can
  make the server produce about another person.

  A struct rather than the `%{login: ..., name: ..., avatar_url: ...}` map
  it was. That map was `shared/api.ts` translated, and the cost of leaving
  it a map was structural: `Ravix.People.Person` was built from one by
  `Map.put(profile, :via, :project)`, so "a profile" and "a person" were
  the same thing to the compiler, with the difference carried by whether
  somebody had remembered the extra key.
  """

  alias Ravix.Accounts.User

  @enforce_keys [:login, :name, :avatar_url]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          login: String.t(),
          name: String.t() | nil,
          avatar_url: String.t() | nil
        }

  @doc "The three published fields of a user row, and nothing else off it."
  @spec from_user(User.t()) :: t()
  def from_user(%User{login: login, name: name, avatar_url: avatar_url}),
    do: %__MODULE__{login: login, name: name, avatar_url: avatar_url}
end

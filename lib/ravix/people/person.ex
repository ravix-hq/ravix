defmodule Ravix.People.Person do
  @moduledoc """
  Somebody in a people list, and how they come to be in it.

  `via` is the whole reason a list is worth reading twice. `:owner` holds
  the project and cannot be removed from anything. `:project` was let into
  the machine and reaches its project-visible tracks, so a *track's* dialog cannot
  take them off --- that is the project's people to change. `:track` was
  named on this one branch. `:pending` is an invitation nobody has taken up
  yet: they can read nothing until they sign in, and withdrawing it is not
  a removal.

  `:creator` identifies the private track creator, independently of project roles.

  With `RAVIX_WORKSPACE_ACCESS` on (ADR 0009), `:workspace` is a live member
  of the project's workspace on a project-visible track, and `:shared` holds
  a permission row on a private one. Neither is the track dialog's to
  remove: the first is the workspace's, the second the creator's sharing.

  Every entry carries one of these values, so a page never has to infer which
  by the absence of a key. `@enforce_keys` covers `via` as well, which is
  what makes that a property rather than a convention: the list used to be
  assembled by `Map.put(profile, :via, :project)`, and a fourth way of
  getting into a list that forgot the `Map.put` would have produced a
  person the dialog renders with no badge and a remove button that
  `Ravix.People.remove/3` then refuses.
  """

  alias Ravix.Accounts.User
  alias Ravix.People.Profile

  @typedoc """
  What this person may do here (ADR 0010): the role on the seat that put
  them in the list. `:owner` and `:creator` are always `:admin`; somebody
  here by way of the workspace works as `:write`. Nil on a pending
  invitation, which grants nothing until it is claimed.
  """
  @type role :: :read | :write | :admin

  @typedoc "How this person comes to be in the list."
  @type via :: :owner | :creator | :project | :workspace | :track | :shared | :pending

  @enforce_keys [:login, :name, :avatar_url, :via]
  defstruct @enforce_keys ++ [role: nil]

  @type t :: %__MODULE__{
          login: String.t(),
          name: String.t() | nil,
          avatar_url: String.t() | nil,
          via: via(),
          role: role() | nil
        }

  @doc "A profile, or the user row behind one, placed in a list by `via`."
  @spec new(Profile.t() | User.t(), via()) :: t()
  def new(%User{} = user, via), do: user |> Profile.from_user() |> new(via)

  def new(%Profile{} = profile, via)
      when via in [:owner, :creator, :project, :workspace, :track, :shared, :pending],
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

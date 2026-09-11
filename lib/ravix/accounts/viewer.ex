defmodule Ravix.Accounts.Viewer do
  @moduledoc """
  The signed-in person, as the shell sees them.

  `id` is GitHub's numeric id rather than the Ravix row id, because this is
  the identity the shell shows and GitHub is where it comes from.

  `has_installation` is asked live rather than stored: it is a fact about
  GitHub that changes without telling us --- somebody installs the App in
  another tab, or an admin removes it --- and a cached `true` is a
  repository picker that renders empty with no explanation. It is enforced
  like the rest, so a viewer built without asking is a build error rather
  than a `nil` that reads as "no installation".
  """

  @enforce_keys [:id, :login, :name, :avatar_url, :has_installation]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          login: String.t(),
          name: String.t() | nil,
          avatar_url: String.t() | nil,
          has_installation: boolean()
        }
end

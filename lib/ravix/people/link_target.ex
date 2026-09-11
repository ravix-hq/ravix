defmodule Ravix.People.LinkTarget do
  @moduledoc """
  What an invite link opens, for the page that asks before claiming it.

  `Ravix.People.link_target/1`'s answer. It exists because of #16: following
  a link used to write the membership, and a GET carries no CSRF token, so
  arriving somewhere and joining it are now two steps with a person's
  decision between them. This is the half the confirmation page needs ---
  `RavixWeb.AuthHTML.confirm/1` --- and it is the only thing an
  unauthenticated-but-signed-in browser learns about a project it has not
  joined, which is why it is four named fields and not the rows.

  `kind` decides the whole page: the heading, the sentence, and the button.
  `track` is `nil` exactly when `kind` is `:project`, and the template
  branches on `kind` rather than on `track`'s absence, so the two must
  agree; a struct is where that pairing is written down once.

  `invited_by` is whoever minted the link, by login, and is the reason to
  name it at all: an invitation is a claim about who is asking, and the one
  piece of it a stranger cannot forge is the account that actually holds
  the project.
  """

  @typedoc "A link opens one track, or a project and every track on it."
  @type kind :: :project | :track

  @enforce_keys [:kind, :project, :track, :invited_by]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          kind: kind(),
          project: String.t(),
          track: String.t() | nil,
          invited_by: String.t() | nil
        }
end

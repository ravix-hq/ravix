defmodule Ravix.People.InviteLink do
  @moduledoc """
  A track's or a project's one invite link, as the dialog that minted it
  sees it.

  Four functions answer with this --- `Ravix.People.link/2`,
  `mint_link/2`, `project_link/2` and `mint_project_link/2` --- and it
  crosses into `lib/ravix_web/`: `RavixWeb.CoreComponents.invite_link/1`
  renders it for both dialogs.

  `url` is the field worth a struct. It is present in exactly one moment,
  the response to a mint, because only the token's hash is stored and the
  link genuinely cannot be shown again; every other read reports a link
  that is *out* as `url: nil`. The component was reading it as
  `@invite[:url]`, which answers `nil` for a key that is absent **and** for
  a key that is misspelled, so "we do not have the URL" and "this template
  asked for the wrong thing" were the same rendering: no link, no error.
  `@invite.url` cannot do that.

  `created_at` and `expires_at` are the link's own, from the row, and are
  what the dialog would need to say how long is left.
  """

  @enforce_keys [:url, :created_at, :expires_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          url: String.t() | nil,
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end

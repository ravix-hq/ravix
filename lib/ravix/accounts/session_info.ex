defmodule Ravix.Accounts.SessionInfo do
  @moduledoc """
  Everything the shell needs before its first render.

  `viewer` is nil for somebody who is not signed in, which is the whole of
  how a page tells. `sign_in_url` is a plain link to a controller rather
  than anything a LiveView does, because the state and its browser cookie
  are minted on that request and a LiveView page cannot set a cookie; both
  URLs are empty strings when no GitHub App is configured, since there is
  nowhere to send a browser.

  A struct with `@enforce_keys`, so a deployment answering with three of
  the four is a build error rather than a shell that renders a sign-in
  button pointing at nothing.
  """

  alias Ravix.Accounts.{Capabilities, Viewer}

  @enforce_keys [:viewer, :sign_in_url, :install_url, :capabilities]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          viewer: Viewer.t() | nil,
          sign_in_url: String.t(),
          install_url: String.t(),
          capabilities: Capabilities.t()
        }
end

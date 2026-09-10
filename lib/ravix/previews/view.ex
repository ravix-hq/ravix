defmodule Ravix.Previews.View do
  @moduledoc """
  A track's preview as the panel shows it.

  `available` and `unavailable_reason` are the deployment's answer rather
  than the track's: a Ravix with no preview domain configured cannot serve
  one for any track, and saying so once here is what keeps the panel from
  offering a button that cannot work.

  `config` is what would actually be used -- the track's override if it has
  one, the project's default otherwise -- and `override` is the track's own,
  separately, because the settings form needs to know which of the two it is
  editing. `url` is absent whenever `available` is false, so a page cannot
  link somewhere it has just been told does not exist.

  A struct with `@enforce_keys` rather than the bare map it was, so a field
  added here and forgotten in `present/1` raises where it is built.
  """

  alias Ravix.Previews.Row

  @enforce_keys [
    :available,
    :unavailable_reason,
    :config,
    :override,
    :state,
    :error,
    :logs,
    :url
  ]

  # Not enforced, because it is only ever present in the answer to an "open"
  # or "restart": a single-use ticket URL, minted for the session that asked
  # and never read back off a row.
  defstruct @enforce_keys ++ [open_url: nil]

  @type t :: %__MODULE__{
          available: boolean(),
          unavailable_reason: String.t() | nil,
          config: Row.config() | nil,
          override: Row.config() | nil,
          state: Row.state(),
          error: String.t() | nil,
          logs: String.t() | nil,
          url: String.t() | nil,
          open_url: String.t() | nil
        }
end

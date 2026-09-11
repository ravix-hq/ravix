defmodule Ravix.Accounts.Capabilities do
  @moduledoc """
  What this deployment can actually do, decided by the server's environment
  rather than by a build flag.

  Every one of the three is a whole feature that is simply absent without
  its credential: no `SPRITES_TOKEN` and there is no terminal or run panel,
  no GitHub App and there is no sign-in or repository picker, no Fountain
  key and there are no machines. The pages read these to render a designed
  empty state naming what is missing, rather than a control that cannot
  work.

  A struct rather than the `Capabilities` map of `shared/api.ts`, so a
  fourth capability added here is a compile-time obligation at every place
  that builds one, instead of a key that reads as `nil` and therefore as
  "switched off".
  """

  @enforce_keys [:exec, :github, :vaults]
  defstruct @enforce_keys

  @type t :: %__MODULE__{exec: boolean(), github: boolean(), vaults: boolean()}
end

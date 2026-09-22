defmodule Ravix.Projects.View do
  @moduledoc """
  A project as a page shows it: the row, its owner's login, and the machine.

  `name` stays bare for edits and tooling; `display_name` prefixes the owner's
  GitHub login only when the viewer is not the owner.

  Things the row cannot answer are folded in here rather than stored.
  `owner_login` is a second read, because the row holds a user id and a
  ribbon needs a name. `machine` is derived from Fountain's conversation
  list, never persisted -- see `Ravix.MachineCache` for why. `role` and
  `access` are the two different questions the UI asks about the caller:
  `role` is owner-or-not, which almost every gate wants, and `access` is how
  they got here, which two places want.

  A struct with `@enforce_keys` rather than the bare map it was, so a field
  added here and forgotten in `present/4` raises where it is built instead
  of going missing on the page.
  """

  @typedoc "Which machine a project is on; see `Ravix.MachineCache.Machine`."
  @type machine :: Ravix.MachineCache.machine()

  @typedoc "How the caller reaches this project: they own it, were let into it, or into tracks on it."
  @type access :: :owner | :project | :tracks | nil

  @enforce_keys [
    :id,
    :name,
    :display_name,
    :repo,
    :repo_private,
    :default_branch,
    :repo_path,
    :runtime,
    :model,
    :rev,
    :machine,
    :created_at,
    :owner_login,
    :role,
    :access
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          display_name: String.t(),
          repo: String.t() | nil,
          repo_private: boolean(),
          default_branch: String.t() | nil,
          repo_path: String.t() | nil,
          runtime: String.t(),
          model: String.t(),
          rev: integer(),
          machine: machine(),
          created_at: DateTime.t(),
          owner_login: String.t(),
          role: :owner | :member,
          access: access()
        }
end

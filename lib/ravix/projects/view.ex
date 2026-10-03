defmodule Ravix.Projects.View do
  @moduledoc """
  A project as a page shows it: the row, its owner's login, the container
  its name is read against, and the machine.

  `name` stays bare for edits and tooling. `container` is what the name is
  read *against* (RAV-128): the prefix a surface shows when the viewer is
  not already inside it, as plain text, so no page looks a workspace up.
  For a workspace project it is the workspace's name, the same for its
  creator and every other member, because under ADR 0009 the creator is
  attribution and not the owner; `container_id` is then the workspace's id,
  so a surface scoped to that workspace can leave the prefix off with
  `label/2`. For a legacy project it is the owner's login, shown to anybody
  it was shared with (ADR 0005), and `container_id` is nil, because nobody
  is "inside" a person. Nil for the owner of a legacy project, for a
  project in the viewer's own personal workspace, and for an owner whose
  account is gone. `display_name` is `label/1`: the name as a surface that
  spans workspaces reads it.

  Things the row cannot answer are folded in here rather than stored.
  `owner_login` is a second read, because the row holds a user id and a
  ribbon needs a name. `machine` is derived from Fountain's conversation
  list, never persisted -- see `Ravix.MachineCache` for why. `role` and
  `access` are the two different questions the UI asks about the caller:
  `role` is owner-or-not, which almost every gate wants, and `access` is how
  they got here, which two places want. `workspace_id` and
  `legacy_duplicate` are ADR 0009's: which workspace the project is the
  repository of, and whether a reviewed migration marked it a duplicate
  that pickers leave out.

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
    :container,
    :container_id,
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

  # The project's workspace (ADR 0009), nil for a legacy project, and
  # whether a reviewed migration marked it a legacy duplicate. Optional, so a
  # view built without them reads as legacy and canonical.
  defstruct @enforce_keys ++ [workspace_id: nil, legacy_duplicate: false]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          display_name: String.t(),
          container: String.t() | nil,
          container_id: String.t() | nil,
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
          access: access(),
          workspace_id: String.t() | nil,
          legacy_duplicate: boolean()
        }

  @doc """
  The prefix a surface shows before the name, or nil for the bare name.

  `within` is the id of the workspace the surface is scoped to, nil for one
  that spans workspaces. The prefix is left off inside the container it
  names, and only there: a workspace project reads bare in its own
  workspace, and a legacy project reads "owner / name" wherever it is
  shown, because its container is a person. A plain map with the two keys
  does, so a page can be rendered from a stub.
  """
  @spec prefix(t() | labelled(), String.t() | nil) :: String.t() | nil
  def prefix(%{container_id: id}, within) when is_binary(id) and id == within, do: nil
  def prefix(%{container: container}, _within), do: container

  @typedoc "What `label/2` reads: the struct, or a stub carrying the three keys."
  @type labelled :: %{
          required(:name) => String.t(),
          required(:container) => String.t() | nil,
          required(:container_id) => String.t() | nil,
          optional(atom()) => any()
        }

  @doc "The name as a surface reads it: `prefix/2` before it, or bare. Spanning without `within`."
  @spec label(t() | labelled(), String.t() | nil) :: String.t()
  def label(view, within \\ nil) do
    case prefix(view, within) do
      nil -> view.name
      prefix -> "#{prefix} / #{view.name}"
    end
  end
end

defmodule Ravix.Workspaces.RepositoryReservation do
  @moduledoc """
  A repository name held back from the creation path (ADR 0009).

  Written when a reviewed migration marks a project as a legacy duplicate,
  and kept after that project is deleted -- `reserved_project_id` has no
  foreign key for that reason -- so the old path cannot quietly create the
  duplicate again. Scoped to a workspace, or, for legacy rows, to the owner
  whose creation path it reserves. Nothing enforces it yet; the creation
  guard that reads it ships before workspace admission.
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "workspace_repository_reservations" do
    field :normalized_repo_full_name, :string
    belongs_to :workspace, Ravix.Workspaces.Workspace
    belongs_to :user, Ravix.Accounts.User
    field :reserved_project_id, :string
    belongs_to :canonical_project, Ravix.Projects.Project
    field :reason, Ecto.Enum, values: [:legacy_duplicate]
    field :created_at, :utc_datetime_usec
  end
end

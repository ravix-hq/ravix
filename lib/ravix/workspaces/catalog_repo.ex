defmodule Ravix.Workspaces.CatalogRepo do
  @moduledoc """
  One repository a workspace's connected installation reaches, as of the
  last catalog refresh (ADR 0009, phase 4b).

  The catalog is a cache of GitHub, refreshed with installation tokens by
  `Ravix.Workspaces.Repositories.refresh/2` and read by pages instead of
  GitHub. `github_repo_id` is the identity that survives a rename or a
  transfer; `normalized_repo_full_name` is `Ravix.Projects.Project.normalize_repo/1`
  of the name GitHub gave at the refresh.
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "workspace_repositories" do
    belongs_to :workspace, Ravix.Workspaces.Workspace
    belongs_to :workspace_installation, Ravix.Workspaces.Installation
    field :github_repo_id, :integer
    field :full_name, :string
    field :normalized_repo_full_name, :string
    field :private, :boolean, default: false
    field :default_branch, :string
    field :pushed_at, :string
    field :refreshed_at, :utc_datetime_usec
  end
end

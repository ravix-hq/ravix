defmodule Ravix.Previews.PreviewDefault do
  @moduledoc """
  A project's run script, stored in the existing preview default row.

  One per project: directory, run command, optional stop command and optional
  HTTP readiness path. Tracks inherit it unless they supply an override. Deleting the row is
  how defaults are cleared.

  `config` is a `:map` column carrying a `Ravix.Previews.Config`, through
  `Ravix.Previews.Config.Type`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "preview_defaults" do
    belongs_to :project, Ravix.Projects.Project, primary_key: true
    field :config, Ravix.Previews.Config.Type
  end

  @doc "The defaults. `config` is a `Ravix.Previews.Config`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(default, attrs) do
    default
    |> cast(attrs, [:project_id, :config])
    |> validate_required([:project_id, :config])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:project_id, name: :preview_defaults_pkey)
  end
end

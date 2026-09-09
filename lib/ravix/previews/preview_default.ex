defmodule Ravix.Previews.PreviewDefault do
  @moduledoc """
  A project's default preview configuration.

  One per project: the directory, the command and the readiness path a
  track's preview uses unless the track overrides them. Deleting the row is
  how defaults are cleared.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "preview_defaults" do
    belongs_to :project, Ravix.Projects.Project, primary_key: true
    field :config, :map
  end

  @doc "The defaults. `config` holds `directory`, `command` and `readinessPath`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(default, attrs) do
    default
    |> cast(attrs, [:project_id, :config])
    |> validate_required([:project_id, :config])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:project_id, name: :preview_defaults_pkey)
  end
end

defmodule Ravix.Projects.Section do
  @moduledoc "A person's named, collapsible group of projects in the sidebar."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "project_sections" do
    field :user_id, :string
    field :name, :string
    field :collapsed, :boolean, default: false
  end

  @doc "Validate a section's editable fields. Ownership is supplied by the context."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(section, attrs) do
    section
    |> cast(attrs, [:name, :collapsed])
    |> update_change(:name, &String.trim/1)
    |> Ravix.Schema.put_new_id()
    |> validate_required([:user_id, :name])
    |> validate_length(:name, max: 80)
    |> unique_constraint(:name, name: :project_sections_user_id_name_index)
  end
end

defmodule Ravix.Projects.Section do
  @moduledoc """
  A person's named, collapsible group of projects in the sidebar, in one of
  their workspaces (RAV-127). Personal: nobody else sees it, and it grants
  nothing.

  `workspace_id` is nil only on a row the release before this one wrote;
  `Ravix.Projects.Sections` reads such a row as the person's personal
  workspace until `Ravix.Workspaces.Backfill` has filled it in.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "project_sections" do
    field :user_id, :string
    field :workspace_id, :string
    field :name, :string
    field :collapsed, :boolean, default: false
  end

  @doc "Validate a section's editable fields. Ownership and workspace are supplied by the context."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(section, attrs) do
    changeset =
      section
      |> cast(attrs, [:name, :collapsed])
      |> update_change(:name, &String.trim/1)
      |> Ravix.Schema.put_new_id()
      |> validate_required([:user_id, :name])
      |> validate_length(:name, max: 80)

    # A second section of one name is refused by the index, and Ecto's word
    # for that is "has already been taken": a fragment that read as "name has
    # already been taken" in a toast (RAV-130). The person sees this under
    # the field they typed in, so it says what happened, with the name.
    taken = "You already have a section called #{get_field(changeset, :name)}."

    changeset
    |> unique_constraint(:name,
      name: :project_sections_user_id_workspace_id_name_index,
      message: taken
    )
    # The previous release's index, narrowed to rows with no workspace.
    |> unique_constraint(:name, name: :project_sections_user_id_name_index, message: taken)
  end
end

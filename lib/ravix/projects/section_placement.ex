defmodule Ravix.Projects.SectionPlacement do
  @moduledoc "A project belongs to at most one section for each person."
  use Ecto.Schema

  @primary_key false
  schema "project_section_placements" do
    field :user_id, :string, primary_key: true
    field :project_id, :string, primary_key: true
    field :section_id, :string
  end
end

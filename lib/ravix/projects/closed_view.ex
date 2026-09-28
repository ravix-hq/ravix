defmodule Ravix.Projects.ClosedView do
  @moduledoc "A person asked to see a project's closed tracks in their sidebar."
  use Ecto.Schema

  @primary_key false
  schema "project_closed_views" do
    field :user_id, :string, primary_key: true
    field :project_id, :string, primary_key: true
  end
end

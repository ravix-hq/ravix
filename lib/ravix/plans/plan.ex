defmodule Ravix.Plans.Plan do
  @moduledoc "A project's durable rationale and optimistic edit version."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  schema "plans" do
    field :project_id, :string
    field :title, :string
    field :summary, :string, default: ""
    field :version, :integer, default: 1
    field :created_by_login, :string
    field :created_by_track_id, :string
    field :archived, :boolean, default: false
    has_many :items, Ravix.Plans.Item
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:title, :summary, :archived])
    |> Ravix.Schema.put_new_id()
    |> validate_required([:title, :project_id, :created_by_login])
    |> validate_length(:title, max: 200)
    |> validate_length(:summary, max: 100_000)
  end
end

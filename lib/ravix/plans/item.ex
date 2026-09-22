defmodule Ravix.Plans.Item do
  @moduledoc "Prompt material and assignment identity. Status is never persisted."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  schema "plan_items" do
    belongs_to :plan, Ravix.Plans.Plan
    field :position, :integer
    field :title, :string
    field :brief, :string, default: ""
    field :acceptance, :string, default: ""
    field :dependencies, {:array, :string}, default: []
    field :track_id, :string
    field :assignment_request, :string
    has_many :notes, Ravix.Plans.Note
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:id, :position, :title, :brief, :acceptance, :dependencies])
    |> Ravix.Schema.put_new_id()
    |> validate_required([:title, :position, :plan_id])
    |> validate_length(:id, max: 100)
    |> validate_format(:id, ~r/^[a-zA-Z0-9_-]+$/)
    |> validate_length(:title, max: 200)
    |> validate_length(:brief, max: 30_000)
    |> validate_length(:acceptance, max: 10_000)
    |> validate_length(:dependencies, max: 100)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:id, name: :plan_items_pkey)
  end
end

defmodule Ravix.Plans.Note do
  @moduledoc "An append-only observation, never evidence that work has completed."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  schema "plan_notes" do
    field :item_id, :string
    field :body, :string
    field :created_by_login, :string
    field :created_by_track_id, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:body])
    |> Ravix.Schema.put_new_id()
    |> validate_required([:body, :item_id, :created_by_login])
    |> validate_length(:body, max: 10_000)
  end
end

defmodule Ravix.Tracks.Thread do
  @moduledoc "A conversation sharing its track's branch and working directory."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @type t :: %__MODULE__{}

  schema "threads" do
    belongs_to :track, Ravix.Tracks.Track
    field :conversation_id, :string
    field :title, :string
    field :created_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:id, :track_id, :conversation_id, :title, :created_at, :closed_at])
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required([:id, :track_id, :title, :created_at])
    |> validate_length(:title, min: 1, max: 200)
    |> foreign_key_constraint(:track_id)
    |> unique_constraint(:conversation_id)
    |> unique_constraint(:id, name: :threads_pkey)
  end
end

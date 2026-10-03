defmodule Ravix.Reviews.Discussion do
  @moduledoc "An immutable diff anchor and the human discussion attached to it."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @type t :: %__MODULE__{}

  schema "review_discussions" do
    field :track_id, :string
    field :revision, :string
    field :path, :string
    field :side, :string
    field :line, :integer
    field :excerpt, :string
    field :resolved, :boolean, default: false
    field :inserted_at, :utc_datetime_usec
    has_many :messages, Ravix.Reviews.Message
  end

  def changeset(discussion, attrs) do
    discussion
    |> cast(attrs, [:track_id, :revision, :path, :side, :line, :excerpt])
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:inserted_at)
    |> validate_required([:track_id, :revision, :path, :side])
    |> validate_inclusion(:side, ["file", "old", "new"])
    |> foreign_key_constraint(:track_id)
    |> check_constraint(:side, name: :review_anchor)
  end
end

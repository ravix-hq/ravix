defmodule Ravix.Reviews.Message do
  @moduledoc "Human-only diff review text; never a transcript note or agent prompt."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @type t :: %__MODULE__{}

  schema "review_messages" do
    belongs_to :discussion, Ravix.Reviews.Discussion
    belongs_to :author, Ravix.Accounts.User
    field :body, :string
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:discussion_id, :author_id, :body])
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:inserted_at)
    |> update_change(:body, &String.trim/1)
    |> validate_required([:discussion_id, :author_id, :body])
    |> validate_length(:body, max: 10_000)
    |> foreign_key_constraint(:discussion_id)
    |> foreign_key_constraint(:author_id)
    |> check_constraint(:body, name: :review_body)
  end
end

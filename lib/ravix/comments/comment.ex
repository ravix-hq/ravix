defmodule Ravix.Comments.Comment do
  @moduledoc """
  A person's note on a thread, for the other people on it to read.

  Human-only, like `Ravix.Plans.Note`: a row here is never a prompt, never
  queued, and never handed to the agent. It sits in the transcript after the
  turn `anchor_turn_id` names (the last visible turn when it was posted), and
  `anchor_event_id` is the newest event the poster had seen, for a reader
  that wants the finer position. Both are nil on a thread with no turns yet.

  Deleting is soft, so the transcript can still say a comment was there.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_body 10_000

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "thread_comments" do
    field :track_id, :string
    field :thread_id, :string
    belongs_to :author, Ravix.Accounts.User
    field :body, :string
    field :conversation_id, :string
    field :anchor_turn_id, :string
    field :anchor_event_id, :integer
    field :inserted_at, :utc_datetime_usec
    field :edited_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
  end

  @doc "The longest body, in characters."
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  @doc "A new comment. Ids and position come from the context, never from the form."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(comment, attrs) do
    comment
    |> cast(attrs, [
      :track_id,
      :thread_id,
      :author_id,
      :body,
      :conversation_id,
      :anchor_turn_id,
      :anchor_event_id
    ])
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:inserted_at)
    |> body()
    |> validate_required([:id, :track_id, :thread_id, :author_id])
    |> foreign_key_constraint(:thread_id)
  end

  @doc "A new body for an existing comment."
  @spec edit_changeset(t(), map()) :: Ecto.Changeset.t()
  def edit_changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body])
    |> body()
    |> put_change(:edited_at, DateTime.utc_now())
  end

  defp body(changeset) do
    changeset
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body], message: "Write something first.")
    |> validate_length(:body, max: @max_body, message: "Keep comments under 10,000 characters.")
    |> check_constraint(:body, name: :thread_comments_body_length)
  end
end

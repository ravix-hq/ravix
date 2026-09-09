defmodule Ravix.PromptQueue.Item do
  @moduledoc """
  An accepted prompt awaiting delivery.

  Work Ravix owes the caller, which must outlive the browser that submitted
  it. `sequence` is the delivery order and the database assigns it; `id` is
  the caller's idempotency key and stays behind as a receipt for retried
  HTTP requests after the row is done. `payload` is the JSON the client
  sent (`prompt` and `images`); it is emptied once the row is `sent` or
  `cancelled` so large attachments are released while the receipt stays.

  Status moves `queued -> sending -> sent`, or to `failed`, or to
  `unconfirmed` when the server restarted mid-delivery and cannot say
  whether Fountain received it, or to `cancelled` when the track closed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:sequence, :id, autogenerate: true}
  @foreign_key_type :string

  @statuses ~w(queued sending failed unconfirmed sent cancelled)a

  @type status :: :queued | :sending | :failed | :unconfirmed | :sent | :cancelled
  @type t :: %__MODULE__{}

  schema "prompt_queue" do
    field :id, :string
    belongs_to :track, Ravix.Tracks.Track
    belongs_to :user, Ravix.Accounts.User
    field :author_login, :string
    field :payload, :string
    field :created_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @statuses, default: :queued
    field :error, :string
  end

  @fields ~w(id track_id user_id author_login payload created_at status error)a

  @doc "The six statuses, in the order the TypeScript declared them."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "A queued prompt. `sequence` is left to the database; `status` defaults to `:queued`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(item, attrs) do
    item
    |> cast(attrs, @fields)
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required([
      :id,
      :track_id,
      :user_id,
      :author_login,
      :payload,
      :created_at,
      :status
    ])
    |> foreign_key_constraint(:track_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:id)
  end
end

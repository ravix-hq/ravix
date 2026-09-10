defmodule Ravix.Accounts.Session do
  @moduledoc """
  A signed-in browser.

  Sessions are stored as hashes, never as the token itself: a copy of this
  database is then not a set of live sessions. The row is keyed by that hash,
  so lookup by cookie is a primary-key read and there is no separate token
  column to leak.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # The session credential's stored form: whoever holds it is signed in. A primary key cannot take `redact:`,
  # so it is kept out of `inspect/1` here instead.
  @derive {Inspect, except: [:token_hash]}
  @primary_key {:token_hash, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "sessions" do
    belongs_to :user, Ravix.Accounts.User
    field :created_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
  end

  @fields ~w(token_hash user_id created_at expires_at)a

  @doc "A session for a user. The caller hashes the token; `expires_at` is required."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, @fields)
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required([:token_hash, :user_id, :created_at, :expires_at])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash, name: :sessions_pkey)
  end
end

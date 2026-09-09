defmodule Ravix.Accounts.OAuthState do
  @moduledoc """
  Short-lived signed state for the two GitHub round trips.

  Rows are deleted on use and swept on age, so a replayed callback finds
  nothing. `kind` says which round trip (sign-in or app installation) the
  state belongs to and `redirect` where to send the browser afterwards.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:state, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "oauth_states" do
    field :kind, :string
    field :redirect, :string
    field :created_at, :utc_datetime_usec
  end

  @fields ~w(state kind redirect created_at)a

  @doc "A state row. `state` is the hashed nonce the caller minted."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(oauth_state, attrs) do
    oauth_state
    |> cast(attrs, @fields)
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required([:state, :kind, :created_at])
    |> unique_constraint(:state, name: :oauth_states_pkey)
  end
end

defmodule Ravix.Accounts.OAuthState do
  @moduledoc """
  Short-lived signed state for the two GitHub round trips.

  Rows are deleted on use and swept on age, so a replayed callback finds
  nothing. `kind` says which round trip (sign-in or app installation) the
  state belongs to and `redirect` where to send the browser afterwards.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(signin install join)a

  @typedoc "Which round trip a parked state belongs to."
  @type kind :: :signin | :install | :join

  # The OAuth attempt's secret, which is what makes the callback unforgeable. A primary key cannot take `redact:`,
  # so it is kept out of `inspect/1` here instead.
  @derive {Inspect, except: [:state]}
  @primary_key {:state, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "oauth_states" do
    field :kind, Ecto.Enum, values: @kinds
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
    |> check_constraint(:kind, name: :oauth_states_kind)
    |> unique_constraint(:state, name: :oauth_states_pkey)
  end
end

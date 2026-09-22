defmodule Ravix.Previews.PreviewAgentGrant do
  @moduledoc """
  The agent's leave to drive a track's preview for one turn.

  One per thread (the unique index on track and thread identity): granting again replaces
  the last grant. `row` is the whole grant as a JSON document (the hash,
  track, user, conversation, prompt, sandbox and sprite it was minted for);
  `expires` is milliseconds since the epoch, and a row past it is dead even
  before it is swept.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # The helper script's bearer token, hashed. A primary key cannot take `redact:`,
  # so it is kept out of `inspect/1` here instead.
  @derive {Inspect, except: [:hash]}
  @primary_key {:hash, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "preview_agent_grants" do
    belongs_to :track, Ravix.Tracks.Track
    belongs_to :user, Ravix.Accounts.User
    field :expires, :integer
    field :thread_id, :string
    field :row, :map
  end

  @fields ~w(hash track_id user_id expires thread_id row)a

  @doc "An agent grant. Every field is required."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> foreign_key_constraint(:track_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:hash, name: :preview_agent_grants_pkey)
    |> unique_constraint(:track_id, name: :preview_agent_grants_thread)
  end
end

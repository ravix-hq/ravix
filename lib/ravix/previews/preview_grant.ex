defmodule Ravix.Previews.PreviewGrant do
  @moduledoc """
  A browser's leave to reach a preview.

  Keyed by the hash of the ticket or session token, tied to the session
  that earned it (and gone with it, by cascade) and to one track. `expires`
  is milliseconds since the epoch, compared with `System.system_time(:millisecond)`
  the way the TypeScript compared it with `Date.now()`. A `ticket` is
  consumed on first use; a `session` grant lasts until it expires or the
  member is removed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:hash, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "preview_grants" do
    belongs_to :track, Ravix.Tracks.Track

    belongs_to :session, Ravix.Accounts.Session,
      foreign_key: :session_hash,
      references: :token_hash

    field :expires, :integer
    field :kind, Ecto.Enum, values: [:ticket, :session]
  end

  @fields ~w(hash track_id session_hash expires kind)a

  @doc "A grant. Every field is required; the caller hashes the token."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> foreign_key_constraint(:track_id)
    |> foreign_key_constraint(:session_hash)
    |> unique_constraint(:hash, name: :preview_grants_pkey)
  end
end

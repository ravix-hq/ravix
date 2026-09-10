defmodule Ravix.Tracks.TrackInvite do
  @moduledoc """
  An invitation to somebody who has not signed in here yet.

  Keyed on GitHub's numeric id, not the login, and that is the whole reason
  this table can exist safely. Logins are renameable, and a login freed by
  a deleted account can be taken by somebody else, so an invitation matched
  on @ana would eventually attach to whoever held that name on the day they
  signed in. The numeric id is stable and never reused. The login and avatar
  are display only, and are allowed to be stale by the time the person
  arrives.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "track_invites" do
    belongs_to :track, Ravix.Tracks.Track, primary_key: true
    field :github_id, :string, primary_key: true
    field :login, :string
    field :avatar_url, :string
    field :invited_by, :string
    field :created_at, :utc_datetime_usec
  end

  @fields ~w(track_id github_id login avatar_url invited_by created_at)a

  @doc "An invitation. Re-inviting the same GitHub id refreshes login and avatar."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, @fields)
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required([:track_id, :github_id, :login, :invited_by, :created_at])
    |> foreign_key_constraint(:track_id)
    |> unique_constraint([:track_id, :github_id], name: :track_invites_pkey)
  end
end

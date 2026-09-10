defmodule Ravix.Tracks.TrackMember do
  @moduledoc """
  Who else is in a track.

  The narrower of the two memberships: somebody invited to one worktree gets
  that worktree. They do not see the project's other tracks, cannot open
  one, and cannot change what is installed on the machine. It is the same
  line paddock draws around a terminal, drawn around a branch instead.
  `Ravix.Projects.ProjectMember` is the wider one, and the two are separate
  tables rather than one with a nullable track_id because they answer
  different questions and are read in different places. They are not,
  however, held at once for one person on one project: the wider grant
  deletes the narrower ones.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "track_members" do
    belongs_to :track, Ravix.Tracks.Track, primary_key: true
    belongs_to :user, Ravix.Accounts.User, primary_key: true
    field :invited_by, :string
    field :created_at, :utc_datetime_usec
  end

  @fields ~w(track_id user_id invited_by created_at)a

  @doc "A membership. `invited_by` is the inviter's user id."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, @fields)
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required(@fields)
    |> foreign_key_constraint(:track_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:track_id, :user_id], name: :track_members_pkey)
  end
end

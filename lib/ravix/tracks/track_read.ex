defmodule Ravix.Tracks.TrackRead do
  @moduledoc """
  When each person last looked at each track.

  Per (track, person) rather than per track, because a shared track is read
  by more than one pair of eyes and Fountain's own unread flag belongs to
  the one account every machine here runs on. It would mark a track read
  for everybody the moment anybody opened it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "track_reads" do
    belongs_to :track, Ravix.Tracks.Track, primary_key: true
    belongs_to :user, Ravix.Accounts.User, primary_key: true
    field :seen_at, :utc_datetime_usec
  end

  @fields ~w(track_id user_id seen_at)a

  @doc "A read receipt. `seen_at` defaults to now."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(read, attrs) do
    read
    |> cast(attrs, @fields)
    |> Ravix.Schema.stamp(:seen_at)
    |> validate_required(@fields)
    |> foreign_key_constraint(:track_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:track_id, :user_id], name: :track_reads_pkey)
  end
end

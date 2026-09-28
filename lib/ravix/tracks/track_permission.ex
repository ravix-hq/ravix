defmodule Ravix.Tracks.TrackPermission do
  @moduledoc """
  A private track shared with one selected member of its workspace
  (ADR 0009, "Selected workspace members").

  Not a `Ravix.Tracks.TrackMember`. That is the legacy seat an invitation
  or link grants anybody, honoured whatever the switch says; this row
  counts only while `Ravix.Config.workspace_access?/0` is on, only on a
  private track in a workspace project, and only while its holder is still
  a live member of that workspace -- `Ravix.Accounts.Access` joins the
  membership on every read, so a removal voids the row without touching it.
  There are no external guests: `Ravix.Tracks.share_with_member/3` refuses
  anybody who is not a member.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "track_permissions" do
    belongs_to :track, Ravix.Tracks.Track, primary_key: true
    belongs_to :user, Ravix.Accounts.User, primary_key: true
    belongs_to :workspace, Ravix.Workspaces.Workspace
    belongs_to :granted_by_user, Ravix.Accounts.User
    field :created_at, :utc_datetime_usec
  end

  @doc "A permission row. Stamps `created_at` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(permission, attrs) do
    permission
    |> cast(attrs, ~w(track_id user_id workspace_id granted_by_user_id created_at)a)
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required(~w(track_id user_id workspace_id created_at)a)
    |> foreign_key_constraint(:track_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:track_id, :user_id], name: :track_permissions_pkey)
  end
end

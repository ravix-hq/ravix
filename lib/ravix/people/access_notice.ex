defmodule Ravix.People.AccessNotice do
  @moduledoc """
  An Inbox note to a track's creator: people who lost access to the track
  when its invite links were retired for workspace sharing (ADR 0009 phase
  5, `Ravix.People.Cutover`).

  `revoked_logins` held a seat on the track and are not members of its
  workspace; `withdrawn_logins` had an invitation waiting that will now
  never be claimed. Both are display only, as the logins were at the time.
  The way back for either is a workspace invitation, and then the Share
  dialog. One per track and recipient.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "track_access_notices" do
    belongs_to :track, Ravix.Tracks.Track
    belongs_to :user, Ravix.Accounts.User
    belongs_to :workspace, Ravix.Workspaces.Workspace
    field :revoked_logins, {:array, :string}, default: []
    field :withdrawn_logins, {:array, :string}, default: []
    field :created_at, :utc_datetime_usec
    field :dismissed_at, :utc_datetime_usec
  end

  @doc "A notice. Mints its id and stamps `created_at` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(notice, attrs) do
    notice
    |> cast(
      attrs,
      ~w(id track_id user_id workspace_id revoked_logins withdrawn_logins created_at)a
    )
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required(~w(id track_id user_id workspace_id created_at)a)
    |> foreign_key_constraint(:track_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:track_id, :user_id])
  end
end

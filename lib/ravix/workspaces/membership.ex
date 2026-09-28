defmodule Ravix.Workspaces.Membership do
  @moduledoc """
  Somebody's role in a workspace: owner, admin or member (ADR 0009).

  Revoked by stamping `revoked_at` rather than deleting, so a removed member
  stays distinguishable from somebody who was never let in. A revoked row
  admits nothing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type role :: :owner | :admin | :member
  @type t :: %__MODULE__{}

  schema "workspace_memberships" do
    belongs_to :workspace, Ravix.Workspaces.Workspace, primary_key: true
    belongs_to :user, Ravix.Accounts.User, primary_key: true
    field :role, Ecto.Enum, values: [:owner, :admin, :member]
    belongs_to :invited_by_user, Ravix.Accounts.User
    field :created_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
  end

  @doc "A membership. Stamps `created_at` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, ~w(workspace_id user_id role invited_by_user_id created_at revoked_at)a)
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required(~w(workspace_id user_id role created_at)a)
    |> check_constraint(:role, name: :workspace_memberships_role)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:workspace_id, :user_id], name: :workspace_memberships_pkey)
  end
end

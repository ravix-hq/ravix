defmodule Ravix.Workspaces.Workspace do
  @moduledoc """
  A workspace: the tenant that will own repositories, memberships and
  installation connections (ADR 0009).

  Expand-only for now. Rows exist -- one personal workspace per user, filled
  by `Ravix.Workspaces.Backfill` -- but nothing authorizes through them yet:
  a project with no `workspace_id` is the legacy layout, and a project with
  one is still reached only through its legacy owner and members until the
  access phase ships.

  `personal_user_id` is set on a personal workspace and nowhere else, and is
  unique, which is what lets the backfill run twice, or on two instances at
  once, without minting a second personal workspace for anybody.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "workspaces" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:personal, :team]
    belongs_to :personal_user, Ravix.Accounts.User
    belongs_to :created_by_user, Ravix.Accounts.User
    field :created_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec

    has_many :memberships, Ravix.Workspaces.Membership
    has_many :installations, Ravix.Workspaces.Installation
  end

  @doc "A workspace. Mints the id and `created_at` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, ~w(id name kind personal_user_id created_by_user_id created_at archived_at)a)
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required(~w(id name kind created_at)a)
    |> check_constraint(:kind, name: :workspaces_kind)
    |> unique_constraint(:personal_user_id, name: :workspaces_personal_user)
    |> unique_constraint(:id, name: :workspaces_pkey)
  end
end

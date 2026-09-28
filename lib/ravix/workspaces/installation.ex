defmodule Ravix.Workspaces.Installation do
  @moduledoc """
  A GitHub App installation explicitly connected to a workspace (ADR 0009).

  An installation may be connected to several workspaces, each through its
  own authorized row; knowing the numeric id is never the authority.
  Revocation stamps `revoked_at` and suspends the repositories bound to it --
  it never selects another installation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "workspace_installations" do
    belongs_to :workspace, Ravix.Workspaces.Workspace
    field :installation_id, :integer
    field :account_login, :string
    belongs_to :connected_by_user, Ravix.Accounts.User
    field :connected_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
  end

  @doc "A connection. Mints the id and `connected_at` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(installation, attrs) do
    installation
    |> cast(
      attrs,
      ~w(id workspace_id installation_id account_login connected_by_user_id connected_at revoked_at)a
    )
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:connected_at)
    |> validate_required(~w(id workspace_id installation_id connected_at)a)
    |> validate_number(:installation_id, greater_than: 0)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :installation_id],
      name: :workspace_installations_workspace_installation
    )
  end
end

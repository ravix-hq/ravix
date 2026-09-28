defmodule Ravix.Workspaces.Invite do
  @moduledoc """
  An invitation to a workspace, waiting on a GitHub login (ADR 0009, phase 4a).

  Written when an owner or admin invites somebody who has not signed in
  here yet, and turned into a membership, then deleted, in the transaction
  of that person's sign-in (`Ravix.Accounts.upsert_user/1`). Revoking one
  deletes it. There are no invite links: the login is the address.

  `login_key` is the login lowercased, which is how GitHub compares logins.
  An owner's invitation, and any invitation for an owner or admin, is
  `protected?/1`: only an owner may change or withdraw it.

  `github_id` is set when GitHub could say whose login it is, and then
  sign-in matches on it and not on the login, because a login can be
  renamed and taken by somebody else in between.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "workspace_invites" do
    belongs_to :workspace, Ravix.Workspaces.Workspace
    field :login, :string
    field :login_key, :string
    field :github_id, :string
    field :avatar_url, :string
    field :role, Ecto.Enum, values: [:owner, :admin, :member]
    belongs_to :invited_by_user, Ravix.Accounts.User
    field :invited_by_role, Ecto.Enum, values: [:owner, :admin, :member]
    field :created_at, :utc_datetime_usec
  end

  @doc "An invitation. Mints the id and `created_at`, and derives `login_key`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invite, attrs) do
    invite
    |> cast(
      attrs,
      ~w(id workspace_id login github_id avatar_url role invited_by_user_id invited_by_role created_at)a
    )
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    |> put_login_key()
    |> validate_required(~w(id workspace_id login login_key role invited_by_role created_at)a)
    |> check_constraint(:role, name: :workspace_invites_role)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:login, name: :workspace_invites_workspace_login)
  end

  @doc "Whether only an owner may change or withdraw this invitation."
  @spec protected?(t()) :: boolean()
  def protected?(%__MODULE__{invited_by_role: :owner}), do: true
  def protected?(%__MODULE__{role: role}), do: role in [:owner, :admin]

  @doc "The comparison form of a GitHub login."
  @spec login_key(String.t()) :: String.t()
  def login_key(login) when is_binary(login), do: String.downcase(login)

  defp put_login_key(changeset) do
    case get_field(changeset, :login) do
      login when is_binary(login) -> put_change(changeset, :login_key, login_key(login))
      _ -> changeset
    end
  end
end

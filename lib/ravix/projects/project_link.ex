defmodule Ravix.Projects.ProjectLink do
  @moduledoc """
  The other way into a project: a link.

  One per project, by primary key, which is what makes minting a new one
  *the* revoke rather than a separate operation somebody has to remember to
  perform. Only the hash is stored: the link is the credential, and a copy
  of this database should not be a set of working invitations. The TTL is
  shorter than a track link's, and people.ts says why: this one admits
  somebody to every branch on the box rather than to the one you were
  looking at when you sent it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "project_links" do
    belongs_to :project, Ravix.Projects.Project, primary_key: true
    # The link is the credential; this is its stored form and belongs in no log.
    field :token_hash, :string, redact: true
    field :created_by, :string
    field :created_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
  end

  @fields ~w(project_id token_hash created_by created_at expires_at)a

  @doc "A link. The caller hashes the token and decides the expiry."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, @fields)
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required(@fields)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:project_id, name: :project_links_pkey)
    |> unique_constraint(:token_hash)
  end
end

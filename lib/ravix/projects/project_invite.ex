defmodule Ravix.Projects.ProjectInvite do
  @moduledoc """
  An invitation to a project for somebody who has not signed in here yet.

  Keyed on GitHub's numeric id for the same reason a track invite is: a
  login is renameable and reusable, so an invitation matched on the name
  would eventually attach to whoever holds it on the day they arrive. Here
  that would hand a stranger the whole machine rather than one branch, so
  the reasoning is the same and the stakes are higher. The login and avatar
  are display only and may be stale by the time the person arrives.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "project_invites" do
    belongs_to :project, Ravix.Projects.Project, primary_key: true
    field :github_id, :string, primary_key: true
    field :login, :string
    field :avatar_url, :string
    field :invited_by, :string
    field :created_at, :utc_datetime_usec
  end

  @fields ~w(project_id github_id login avatar_url invited_by created_at)a

  @doc "An invitation. Re-inviting the same GitHub id refreshes login and avatar."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, @fields)
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required([:project_id, :github_id, :login, :invited_by, :created_at])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:project_id, :github_id], name: :project_invites_pkey)
  end
end

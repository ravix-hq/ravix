defmodule Ravix.Projects.ProjectMember do
  @moduledoc """
  Who else is in a project.

  The wider membership, and the three tables beside it are the same three
  the track has, one level up: a row per person, a row per person who has
  not signed in yet, and one link. Somebody here reaches every track on the
  project, the ones that exist and the ones opened tomorrow, and may open
  tracks of their own. They still cannot reach the project's controls:
  settings, packages, secrets, the rebuild and the delete stay with the
  owner, because those are the machine rather than the work on it.

  The wider grant deletes the narrower ones: a person is never both a
  project member and a track member on the same project.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "project_members" do
    belongs_to :project, Ravix.Projects.Project, primary_key: true
    belongs_to :user, Ravix.Accounts.User, primary_key: true
    field :invited_by, :string
    field :created_at, :utc_datetime_usec
  end

  @fields ~w(project_id user_id invited_by created_at)a

  @doc "A membership. `invited_by` is the inviter's user id."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, @fields)
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required(@fields)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:project_id, :user_id], name: :project_members_pkey)
  end
end

defmodule Ravix.Projects.Project do
  @moduledoc """
  Which project is which.

  A row, because a project's name and its repository are Ravix's ideas
  rather than Fountain's. The three Fountain ids are the project. They are
  written once, at creation, and never updated: the sandbox is built from
  them, so a row that changed one would be a row pointing at a different
  machine. The one exception is `agent_id`, which moves on a rebuild and
  nothing else: retiring the agent is what changes the sandbox identity,
  while the environment and vault stay.

  `rev` is the settings revision. It is bumped whenever something Fountain
  injects at session start changes (a secret, an MCP server, a skill, the
  system prompt). Tracks already open carry the old number and are badged
  as running older settings, which is true and cannot be worked out any
  other way.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "projects" do
    belongs_to :user, Ravix.Accounts.User
    field :name, :string
    field :repo_full_name, :string
    field :repo_private, :boolean, default: false
    field :default_branch, :string
    field :installation_id, :integer
    field :agent_id, :string
    field :environment_id, :string
    field :vault_id, :string
    field :runtime, :string
    field :model, :string
    field :rev, :integer, default: 1
    field :instructions, :string, default: ""
    field :created_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec

    has_many :tracks, Ravix.Tracks.Track
    has_many :members, Ravix.Projects.ProjectMember
    has_many :invites, Ravix.Projects.ProjectInvite
    has_one :link, Ravix.Projects.ProjectLink
    has_one :preview_default, Ravix.Previews.PreviewDefault
  end

  @fields ~w(id user_id name repo_full_name repo_private default_branch installation_id
             agent_id environment_id vault_id runtime model rev instructions created_at archived_at)a
  @required ~w(id user_id name agent_id environment_id runtime model rev created_at)a

  @doc "A project with its three Fountain ids. Mints the id and `created_at` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, @fields)
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    # Instructions may be cleared; the column is NOT NULL DEFAULT '' and
    # `cast/3` turns "" into nil, so put the empty string back.
    |> update_change(:instructions, &(&1 || ""))
    |> validate_required(@required)
    |> validate_number(:rev, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:id, name: :projects_pkey)
  end
end
